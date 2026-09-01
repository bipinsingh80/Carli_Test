-- Fixed version of RPC_Redirect.sql.
--
-- Root cause: UTL_HTTP.SET_FOLLOW_REDIRECT only auto-follows redirects for
-- GET/HEAD requests. For POST it does not resend the request body on the
-- new URL, so the 3xx status from GET_RESPONSE is simply handed back to the
-- caller unchanged -- which is exactly the "still see 301" symptom here.
-- (See IBM's writeup of the same UTL_HTTP behavior:
--  https://www.ibm.com/support/pages/node/7223490)
--
-- Fix: don't rely on SET_FOLLOW_REDIRECT for a POST call. Inspect the
-- status code ourselves, and when it is a redirect, read the Location
-- header, close the response, and re-issue the same POST (headers +
-- payload) against the resolved URL, up to a hop limit.

DECLARE
    l_req            UTL_HTTP.req;
    l_res            UTL_HTTP.resp;
    l_err_message    VARCHAR2 (1000);
    l_rpc_url        VARCHAR2 (1000);       -- v1.15

    l_clob           CLOB;
    l_year           VARCHAR2 (10);
    l_make           VARCHAR2 (100);
    l_model          VARCHAR2 (100);
    l_org            VARCHAR2 (10);
    l_stock_number   VARCHAR2 (10);
    l_tire_desc      VARCHAR2 (500) := '';
    l_text           VARCHAR2 (32767);
    l_payload        VARCHAR2 (4000)
        := '{ "year": 2020, "make": "Hyundai", "model": "Tucson", "vin": "KM8J23A47LU100705", "organizationCode": "CON", "parts": {"uid":8682888, "partTypeCode": "REAR_TIRE_WHEEL_STUD", "unitPrice": 0 } }';

    l_op_grp_code   NUMBER;
    l_vin           VARCHAR2(100);

    l_location       VARCHAR2 (4000);
    l_scheme_end     PLS_INTEGER;
    l_host_end       PLS_INTEGER;
    l_scheme         VARCHAR2 (10);
    l_authority      VARCHAR2 (4000);
    l_hops           PLS_INTEGER := 0;
    c_max_redirects  CONSTANT PLS_INTEGER := 5;

    CURSOR c_connect_details IS SELECT * FROM xxvps_intg.xxvps_outb_dtls;

    rec_connect      c_connect_details%ROWTYPE;

BEGIN

    OPEN c_connect_details;
    FETCH c_connect_details   INTO rec_connect;
    CLOSE c_connect_details;

    UTL_HTTP.set_wallet (rec_connect.wallet_path);      -- v1.18        removed ->  , rec_connect.wallet_pwd);

    -- Do not let UTL_HTTP raise on non-2xx; we want to inspect
    -- l_res.status_code ourselves, including 3xx.
    UTL_HTTP.set_response_error_check (FALSE);

    DBMS_LOB.createtemporary (l_clob, FALSE);

	SELECT lv.meaning
	  INTO l_rpc_url
	  FROM xxvps_lookup_types lt, xxvps_lookup_values lv
	 WHERE lt.lookup_type = 'MISC'
	   AND lt.lkp_type_seq_id = lv.lkp_type_seq_id
	   AND lv.lookup_code = 'RPC_URL';

    LOOP
        l_req := UTL_HTTP.begin_request (l_rpc_url, 'POST', 'HTTP/1.1');

        UTL_HTTP.set_header (l_req, 'user-agent', 'mozilla/4.0');
        UTL_HTTP.set_header (l_req, 'content-type', 'application/json');
        UTL_HTTP.set_header (l_req, 'Content-Length', LENGTH (l_payload));
        UTL_HTTP.write_text (l_req, l_payload);
        l_res := UTL_HTTP.get_response (l_req);

        DBMS_OUTPUT.PUT_LINE('Post Status ' || l_res.status_code);

        EXIT WHEN l_res.status_code NOT IN ('301', '302', '303', '307', '308');

        BEGIN
            UTL_HTTP.get_header_by_name (l_res, 'Location', l_location);
        EXCEPTION
            WHEN UTL_HTTP.header_not_found THEN
                l_location := NULL;
        END;

        UTL_HTTP.end_response (l_res);

        l_hops := l_hops + 1;
        IF l_location IS NULL OR l_hops > c_max_redirects THEN
            RAISE_APPLICATION_ERROR (-20001,
                'Redirect from ' || l_rpc_url || ' could not be followed (hop ' || l_hops || ', Location: ' || l_location || ')');
        END IF;

        -- Resolve Location against the current URL (absolute / protocol-relative / root-relative).
        IF REGEXP_LIKE (l_location, '^[a-zA-Z][a-zA-Z0-9+.-]*://') THEN
            l_rpc_url := l_location;
        ELSE
            l_scheme_end := INSTR (l_rpc_url, '://');
            l_scheme     := SUBSTR (l_rpc_url, 1, l_scheme_end - 1);
            l_host_end   := INSTR (l_rpc_url, '/', l_scheme_end + 4);
            IF l_host_end = 0 THEN
                l_host_end := LENGTH (l_rpc_url) + 1;
            END IF;
            l_authority := SUBSTR (l_rpc_url, l_scheme_end + 3, l_host_end - (l_scheme_end + 3));

            IF SUBSTR (l_location, 1, 2) = '//' THEN
                l_rpc_url := l_scheme || ':' || l_location;
            ELSIF SUBSTR (l_location, 1, 1) = '/' THEN
                l_rpc_url := l_scheme || '://' || l_authority || l_location;
            ELSE
                RAISE_APPLICATION_ERROR (-20002, 'Unsupported relative Location header: ' || l_location);
            END IF;
        END IF;

        DBMS_OUTPUT.PUT_LINE ('Redirected (hop ' || l_hops || ') to ' || l_rpc_url);
        -- loop again: re-POST the same payload/headers to the resolved URL
    END LOOP;

    BEGIN
        LOOP
            UTL_HTTP.read_text (l_res, l_text, 32766);

            DBMS_LOB.writeappend (l_clob, LENGTH (l_text), l_text);
        END LOOP;
    EXCEPTION
        WHEN UTL_HTTP.end_of_body
        THEN
            UTL_HTTP.end_response (l_res);
    END;

    -- Uncomment for debugging
    DBMS_OUTPUT.PUT_LINE('Response from RPC -'||l_clob);


    UTL_HTTP.end_response (l_res);
    UTL_HTTP.end_request (l_req);
END;
/
