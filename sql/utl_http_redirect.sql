-- UTL_HTTP has no built-in "follow redirects" option: GET_RESPONSE simply
-- returns the 3xx status and a Location header, so redirect-following has to
-- be implemented as an explicit loop. This package does that.
--
-- Prereqs (run once, as a DBA-privileged user, before this will work):
--   BEGIN
--     DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
--       host        => 'example.com',                 -- or '*' for any host
--       ace         => xs$ace_type(
--                        privilege_list => xs$name_list('http', 'http_proxy'),
--                        principal_name => 'MY_APP_USER',
--                        principal_type => xs_acl.ptype_db)
--     );
--   END;
--   /
-- (11g and earlier used DBMS_NETWORK_ACL_ADMIN.CREATE_ACL / ASSIGN_ACL /
-- ADD_PRIVILEGE instead of APPEND_HOST_ACE.)

CREATE OR REPLACE PACKAGE utl_http_redirect AUTHID CURRENT_USER AS

  -- Fetches p_url, following redirects (301, 302, 303, 307, 308) up to
  -- p_max_redirects hops. Raises an application error if the hop limit is
  -- exceeded or a non-2xx/3xx status is returned.
  FUNCTION get_with_redirects(
    p_url           IN VARCHAR2,
    p_max_redirects IN PLS_INTEGER DEFAULT 5,
    p_wallet_path   IN VARCHAR2    DEFAULT NULL,
    p_wallet_pwd    IN VARCHAR2    DEFAULT NULL
  ) RETURN CLOB;

END utl_http_redirect;
/

CREATE OR REPLACE PACKAGE BODY utl_http_redirect AS

  -- Resolves a Location header value against the URL it was returned for.
  -- Handles absolute URLs, protocol-relative (//host/path) and
  -- root-relative (/path) forms; anything else is treated as already
  -- resolvable and returned unchanged.
  FUNCTION resolve_location(
    p_base_url IN VARCHAR2,
    p_location IN VARCHAR2
  ) RETURN VARCHAR2 IS
    v_scheme_end PLS_INTEGER;
    v_host_end   PLS_INTEGER;
    v_scheme     VARCHAR2(10);
    v_authority  VARCHAR2(4000);
  BEGIN
    IF p_location IS NULL THEN
      RAISE_APPLICATION_ERROR(-20001, 'Redirect response had no Location header');
    END IF;

    -- Already absolute (has a scheme://).
    IF REGEXP_LIKE(p_location, '^[a-zA-Z][a-zA-Z0-9+.-]*://') THEN
      RETURN p_location;
    END IF;

    v_scheme_end := INSTR(p_base_url, '://');
    v_scheme     := SUBSTR(p_base_url, 1, v_scheme_end - 1);
    v_host_end   := INSTR(p_base_url, '/', v_scheme_end + 4);
    IF v_host_end = 0 THEN
      v_host_end := LENGTH(p_base_url) + 1;
    END IF;
    v_authority := SUBSTR(p_base_url, v_scheme_end + 3, v_host_end - (v_scheme_end + 3));

    -- Protocol-relative: //host/path
    IF SUBSTR(p_location, 1, 2) = '//' THEN
      RETURN v_scheme || ':' || p_location;
    END IF;

    -- Root-relative: /path
    IF SUBSTR(p_location, 1, 1) = '/' THEN
      RETURN v_scheme || '://' || v_authority || p_location;
    END IF;

    -- Relative to the current path; keep it simple and strip to the
    -- directory of the base URL.
    RETURN v_scheme || '://' || v_authority ||
           SUBSTR(SUBSTR(p_base_url, v_host_end),
                  1,
                  NVL(NULLIF(INSTR(SUBSTR(p_base_url, v_host_end), '/', -1), 0), 1)) ||
           p_location;
  END resolve_location;

  FUNCTION get_with_redirects(
    p_url           IN VARCHAR2,
    p_max_redirects IN PLS_INTEGER DEFAULT 5,
    p_wallet_path   IN VARCHAR2    DEFAULT NULL,
    p_wallet_pwd    IN VARCHAR2    DEFAULT NULL
  ) RETURN CLOB IS
    v_req      UTL_HTTP.REQ;
    v_resp     UTL_HTTP.RESP;
    v_url      VARCHAR2(4000) := p_url;
    v_location VARCHAR2(4000);
    v_buffer   VARCHAR2(32767);
    v_body     CLOB;
    v_hops     PLS_INTEGER := 0;
  BEGIN
    DBMS_LOB.CREATETEMPORARY(v_body, TRUE);

    -- Do not let UTL_HTTP itself raise on 4xx/5xx: we want to inspect
    -- resp.status_code ourselves instead of catching an exception.
    UTL_HTTP.SET_RESPONSE_ERROR_CHECK(FALSE);

    LOOP
      IF p_wallet_path IS NOT NULL THEN
        UTL_HTTP.SET_WALLET(p_wallet_path, p_wallet_pwd);
      END IF;

      v_req := UTL_HTTP.BEGIN_REQUEST(v_url, 'GET', 'HTTP/1.1');
      v_resp := UTL_HTTP.GET_RESPONSE(v_req);

      IF v_resp.status_code IN ('301', '302', '303', '307', '308') THEN
        BEGIN
          UTL_HTTP.GET_HEADER_BY_NAME(v_resp, 'Location', v_location);
        EXCEPTION
          WHEN UTL_HTTP.HEADER_NOT_FOUND THEN
            v_location := NULL;
        END;

        UTL_HTTP.END_RESPONSE(v_resp);

        v_hops := v_hops + 1;
        IF v_hops > p_max_redirects THEN
          RAISE_APPLICATION_ERROR(-20002,
            'Exceeded ' || p_max_redirects || ' redirects fetching ' || p_url);
        END IF;

        v_url := resolve_location(v_url, v_location);
        -- loop again and re-request v_url (as GET, per 303 semantics and
        -- common practice for 301/302; add method/body pass-through here
        -- if you need to preserve a POST for 307/308)
      ELSIF v_resp.status_code = '200' THEN
        BEGIN
          LOOP
            UTL_HTTP.READ_TEXT(v_resp, v_buffer, 32767);
            DBMS_LOB.WRITEAPPEND(v_body, LENGTH(v_buffer), v_buffer);
          END LOOP;
        EXCEPTION
          WHEN UTL_HTTP.END_OF_BODY THEN
            NULL;
        END;
        UTL_HTTP.END_RESPONSE(v_resp);
        EXIT;
      ELSE
        UTL_HTTP.END_RESPONSE(v_resp);
        RAISE_APPLICATION_ERROR(-20003,
          'Request to ' || v_url || ' failed with status ' || v_resp.status_code);
      END IF;
    END LOOP;

    RETURN v_body;
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        UTL_HTTP.END_RESPONSE(v_resp);
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;
      RAISE;
  END get_with_redirects;

END utl_http_redirect;
/
