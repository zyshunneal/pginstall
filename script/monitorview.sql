--
-- PostgreSQL database dump
--

-- Dumped from database version 10.4
-- Dumped by pg_dump version 10.3


--
-- Name: monitor; Type: SCHEMA; Schema: -; Owner: postgres
--
drop extension pg_stat_statements cascade;
drop schema monitor cascade;


CREATE SCHEMA monitor;

ALTER SCHEMA monitor OWNER TO postgres;

create extension pg_stat_statements with schema monitor;
--
-- Name: pg_stat_repl(); Type: FUNCTION; Schema: monitor; Owner: postgres
--

CREATE FUNCTION monitor.pg_stat_repl() RETURNS SETOF pg_stat_replication
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN RETURN QUERY (SELECT *
                    FROM pg_catalog.pg_stat_replication);
END
$$;


ALTER FUNCTION monitor.pg_stat_repl() OWNER TO postgres;

--
-- Name: select_aging_tables(); Type: FUNCTION; Schema: monitor; Owner: postgres
--

CREATE FUNCTION monitor.select_aging_tables() RETURNS SETOF text
    LANGUAGE sql
    AS $$
WITH aging_tables AS (SELECT
                        nsp.nspname || '.' || c.relname                    as fullname,
                        greatest(age(c.relfrozenxid), age(t.relfrozenxid)) as age,
                        round(c.relpages :: NUMERIC / 128, 3)              as size_mb
                      FROM pg_class c
                        LEFT JOIN pg_class t ON c.reltoastrelid = t.oid
                        LEFT JOIN pg_namespace nsp ON c.relnamespace = nsp.oid
                      WHERE c.relkind IN ('r', 'm') AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
)
SELECT fullname FROM aging_tables WHERE age > 81921024 ORDER BY size_mb ASC;
-- index bigger than 10g require manual check
$$;


ALTER FUNCTION monitor.select_aging_tables() OWNER TO postgres;

--
-- Name: FUNCTION select_aging_tables(); Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON FUNCTION monitor.select_aging_tables() IS 'list tables that needs vacuum freeze';


--
-- Name: select_bloat_indexes(); Type: FUNCTION; Schema: monitor; Owner: postgres
--

CREATE FUNCTION monitor.select_bloat_indexes() RETURNS SETOF text
    LANGUAGE sql
    AS $$
WITH indexes_bloat AS (
    SELECT
      nspname || '.' || idxname as idx_name,
      actual_mb,
      bloat_pct
    FROM monitor.pg_bloat_indexes
    WHERE nspname NOT IN ('dba', 'monitor', 'trash') AND bloat_pct > 20
    ORDER BY 2 DESC,3 DESC
)
(SELECT idx_name FROM indexes_bloat WHERE actual_mb < 100 AND bloat_pct > 40 ORDER BY bloat_pct DESC LIMIT 30) UNION -- 30 small
(SELECT idx_name FROM indexes_bloat WHERE actual_mb BETWEEN 100 AND 2000 ORDER BY bloat_pct DESC LIMIT 10) UNION -- 10 medium
(SELECT idx_name FROM indexes_bloat WHERE actual_mb BETWEEN 2000 AND 10000 ORDER BY bloat_pct DESC LIMIT 3) UNION -- 3 big
(SELECT idx_name FROM indexes_bloat WHERE actual_mb < 10000 ORDER BY bloat_pct DESC LIMIT 5); -- 5 at least
-- index bigger than 10g require manual check
$$;


ALTER FUNCTION monitor.select_bloat_indexes() OWNER TO postgres;

--
-- Name: FUNCTION select_bloat_indexes(); Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON FUNCTION monitor.select_bloat_indexes() IS 'list indexes that needs rebuild';


--
-- Name: select_bloat_tables(); Type: FUNCTION; Schema: monitor; Owner: postgres
--

CREATE FUNCTION monitor.select_bloat_tables() RETURNS SETOF text
    LANGUAGE sql
    AS $$
WITH tables_bloat AS (
    SELECT
      nspname || '.' || relname as relname,
      actual_mb,
      bloat_pct
    FROM monitor.pg_bloat_tables
    WHERE nspname NOT IN ('dba', 'monitor', 'trash') AND bloat_pct > 20
    ORDER BY 2 DESC,3 DESC
)
(SELECT relname FROM tables_bloat WHERE actual_mb < 200 AND bloat_pct > 40 ORDER BY bloat_pct DESC LIMIT 30) UNION -- < 200m small table x 30
(SELECT relname FROM tables_bloat WHERE actual_mb BETWEEN 200 AND 2000 ORDER BY bloat_pct DESC LIMIT 10) UNION -- 10 medium table
(SELECT relname FROM tables_bloat WHERE actual_mb BETWEEN 2000 AND 10000 ORDER BY bloat_pct DESC  LIMIT 3) UNION -- 3 big table
(SELECT relname FROM tables_bloat WHERE actual_mb < 10000 ORDER BY bloat_pct DESC LIMIT 10); -- 5 at least
-- bigger table require manual check
$$;


ALTER FUNCTION monitor.select_bloat_tables() OWNER TO postgres;

--
-- Name: FUNCTION select_bloat_tables(); Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON FUNCTION monitor.select_bloat_tables() IS 'list tables that needs repack';


--
-- Name: pg_aging_tables; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.pg_aging_tables AS
 SELECT c.oid AS relid,
    c.relname,
    nsp.nspname,
    (((nsp.nspname)::text || '.'::text) || (c.relname)::text) AS fullname,
    GREATEST(age(c.relfrozenxid), age(t.relfrozenxid)) AS age,
    round(((c.relpages)::numeric / (128)::numeric), 3) AS size_mb
   FROM ((pg_class c
     LEFT JOIN pg_class t ON ((c.reltoastrelid = t.oid)))
     LEFT JOIN pg_namespace nsp ON ((c.relnamespace = nsp.oid)))
  WHERE ((c.relkind = ANY (ARRAY['r'::"char", 'm'::"char"])) AND (nsp.nspname <> ALL (ARRAY['pg_catalog'::name, 'information_schema'::name])))
  ORDER BY GREATEST(age(c.relfrozenxid), age(t.relfrozenxid)) DESC;


ALTER TABLE monitor.pg_aging_tables OWNER TO postgres;

--
-- Name: VIEW pg_aging_tables; Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON VIEW monitor.pg_aging_tables IS 'monitor table age';


--
-- Name: pg_bloat_indexes; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.pg_bloat_indexes AS
 WITH btree_index_atts AS (
         SELECT pg_namespace.nspname,
            indexclass.relname AS index_name,
            indexclass.reltuples,
            indexclass.relpages,
            pg_index.indrelid,
            pg_index.indexrelid,
            indexclass.relam,
            tableclass.relname AS tablename,
            (regexp_split_to_table((pg_index.indkey)::text, ' '::text))::smallint AS attnum,
            pg_index.indexrelid AS index_oid
           FROM ((((pg_index
             JOIN pg_class indexclass ON ((pg_index.indexrelid = indexclass.oid)))
             JOIN pg_class tableclass ON ((pg_index.indrelid = tableclass.oid)))
             JOIN pg_namespace ON ((pg_namespace.oid = indexclass.relnamespace)))
             JOIN pg_am ON ((indexclass.relam = pg_am.oid)))
          WHERE ((pg_am.amname = 'btree'::name) AND (indexclass.relpages > 0))
        ), index_item_sizes AS (
         SELECT ind_atts.nspname,
            ind_atts.index_name,
            ind_atts.reltuples,
            ind_atts.relpages,
            ind_atts.relam,
            ind_atts.indrelid AS table_oid,
            ind_atts.index_oid,
            (current_setting('block_size'::text))::numeric AS bs,
            8 AS maxalign,
            24 AS pagehdr,
                CASE
                    WHEN (max(COALESCE(pg_stats.null_frac, (0)::real)) = (0)::double precision) THEN 2
                    ELSE 6
                END AS index_tuple_hdr,
            sum((((1)::double precision - COALESCE(pg_stats.null_frac, (0)::real)) * (COALESCE(pg_stats.avg_width, 1024))::double precision)) AS nulldatawidth
           FROM ((pg_attribute
             JOIN btree_index_atts ind_atts ON (((pg_attribute.attrelid = ind_atts.indexrelid) AND (pg_attribute.attnum = ind_atts.attnum))))
             JOIN pg_stats ON (((pg_stats.schemaname = ind_atts.nspname) AND (((pg_stats.tablename = ind_atts.tablename) AND ((pg_stats.attname)::text = pg_get_indexdef(pg_attribute.attrelid, (pg_attribute.attnum)::integer, true))) OR ((pg_stats.tablename = ind_atts.index_name) AND (pg_stats.attname = pg_attribute.attname))))))
          WHERE (pg_attribute.attnum > 0)
          GROUP BY ind_atts.nspname, ind_atts.index_name, ind_atts.reltuples, ind_atts.relpages, ind_atts.relam, ind_atts.indrelid, ind_atts.index_oid, (current_setting('block_size'::text))::numeric, 8::integer
        ), index_aligned_est AS (
         SELECT index_item_sizes.maxalign,
            index_item_sizes.bs,
            index_item_sizes.nspname,
            index_item_sizes.index_name,
            index_item_sizes.reltuples,
            index_item_sizes.relpages,
            index_item_sizes.relam,
            index_item_sizes.table_oid,
            index_item_sizes.index_oid,
            COALESCE(ceil((((index_item_sizes.reltuples * ((((((((6 + index_item_sizes.maxalign) -
                CASE
                    WHEN ((index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE (index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign)
                END))::double precision + index_item_sizes.nulldatawidth) + (index_item_sizes.maxalign)::double precision) - (
                CASE
                    WHEN (((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE ((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign)
                END)::double precision))::numeric)::double precision) / ((index_item_sizes.bs - (index_item_sizes.pagehdr)::numeric))::double precision) + (1)::double precision)), (0)::double precision) AS expected
           FROM index_item_sizes
        ), raw_bloat AS (
         SELECT current_database() AS dbname,
            index_aligned_est.nspname,
            pg_class.relname AS table_name,
            index_aligned_est.index_name,
            (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric) AS totalbytes,
            index_aligned_est.expected,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric)
                END AS wastedbytes,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (((index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric) * (100)::numeric) / (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric))
                END AS realbloat,
            pg_relation_size((index_aligned_est.table_oid)::regclass) AS table_bytes,
            stat.idx_scan AS index_scans
           FROM ((index_aligned_est
             JOIN pg_class ON ((pg_class.oid = index_aligned_est.table_oid)))
             JOIN pg_stat_user_indexes stat ON ((index_aligned_est.index_oid = stat.indexrelid)))
        ), format_bloat AS (
         SELECT raw_bloat.dbname AS database_name,
            raw_bloat.nspname AS schema_name,
            raw_bloat.table_name,
            raw_bloat.index_name,
            round(raw_bloat.realbloat) AS bloat_pct,
            round((raw_bloat.wastedbytes / (((1024)::double precision ^ (2)::double precision))::numeric)) AS bloat_mb,
            round((raw_bloat.totalbytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS index_mb,
            round(((raw_bloat.table_bytes)::numeric / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS table_mb,
            raw_bloat.index_scans
           FROM raw_bloat
        )
 SELECT format_bloat.database_name AS datname,
    format_bloat.schema_name AS nspname,
    format_bloat.table_name AS relname,
    format_bloat.index_name AS idxname,
    format_bloat.index_scans AS idx_scans,
    format_bloat.bloat_pct,
    format_bloat.table_mb,
    (format_bloat.index_mb - format_bloat.bloat_mb) AS actual_mb,
    format_bloat.bloat_mb,
    format_bloat.index_mb AS total_mb
   FROM format_bloat
  ORDER BY format_bloat.bloat_mb DESC;


ALTER TABLE monitor.pg_bloat_indexes OWNER TO postgres;

--
-- Name: VIEW pg_bloat_indexes; Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON VIEW monitor.pg_bloat_indexes IS 'index bloat monitor';


--
-- Name: pg_bloat_tables; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.pg_bloat_tables AS
 WITH constants AS (
         SELECT (current_setting('block_size'::text))::numeric AS bs,
            23 AS hdr,
            8 AS ma
        ), no_stats AS (
         SELECT columns.table_schema,
            columns.table_name,
            (psut.n_live_tup)::numeric AS est_rows,
            (pg_table_size((psut.relid)::regclass))::numeric AS table_size
           FROM ((information_schema.columns
             JOIN pg_stat_user_tables psut ON ((((columns.table_schema)::name = psut.schemaname) AND ((columns.table_name)::name = psut.relname))))
             LEFT JOIN pg_stats ON ((((columns.table_schema)::name = pg_stats.schemaname) AND ((columns.table_name)::name = pg_stats.tablename) AND ((columns.column_name)::name = pg_stats.attname))))
          WHERE ((pg_stats.attname IS NULL) AND ((columns.table_schema)::text <> ALL (ARRAY[('pg_catalog'::character varying)::text, ('information_schema'::character varying)::text])))
          GROUP BY columns.table_schema, columns.table_name, psut.relid, psut.n_live_tup
        ), null_headers AS (
         SELECT ((constants.hdr + 1) + (sum(
                CASE
                    WHEN (pg_stats.null_frac <> (0)::double precision) THEN 1
                    ELSE 0
                END) / 8)) AS nullhdr,
            sum((((1)::double precision - pg_stats.null_frac) * (pg_stats.avg_width)::double precision)) AS datawidth,
            max(pg_stats.null_frac) AS maxfracsum,
            pg_stats.schemaname,
            pg_stats.tablename,
            constants.hdr,
            constants.ma,
            constants.bs
           FROM ((pg_stats
             CROSS JOIN constants)
             LEFT JOIN no_stats ON (((pg_stats.schemaname = (no_stats.table_schema)::name) AND (pg_stats.tablename = (no_stats.table_name)::name))))
          WHERE ((pg_stats.schemaname <> ALL (ARRAY['pg_catalog'::name, 'information_schema'::name])) AND (no_stats.table_name IS NULL) AND (EXISTS ( SELECT 1
                   FROM information_schema.columns
                  WHERE ((pg_stats.schemaname = (columns.table_schema)::name) AND (pg_stats.tablename = (columns.table_name)::name)))))
          GROUP BY pg_stats.schemaname, pg_stats.tablename, constants.hdr, constants.ma, constants.bs
        ), data_headers AS (
         SELECT null_headers.ma,
            null_headers.bs,
            null_headers.hdr,
            null_headers.schemaname,
            null_headers.tablename,
            ((null_headers.datawidth + (((null_headers.hdr + null_headers.ma) -
                CASE
                    WHEN ((null_headers.hdr % null_headers.ma) = 0) THEN null_headers.ma
                    ELSE (null_headers.hdr % null_headers.ma)
                END))::double precision))::numeric AS datahdr,
            (null_headers.maxfracsum * (((null_headers.nullhdr + null_headers.ma) -
                CASE
                    WHEN ((null_headers.nullhdr % (null_headers.ma)::bigint) = 0) THEN (null_headers.ma)::bigint
                    ELSE (null_headers.nullhdr % (null_headers.ma)::bigint)
                END))::double precision) AS nullhdr2
           FROM null_headers
        ), table_estimates AS (
         SELECT data_headers.schemaname,
            data_headers.tablename,
            data_headers.bs,
            (pg_class.reltuples)::numeric AS est_rows,
            ((pg_class.relpages)::numeric * data_headers.bs) AS table_bytes,
            (ceil(((pg_class.reltuples * (((((data_headers.datahdr)::double precision + data_headers.nullhdr2) + (4)::double precision) + (data_headers.ma)::double precision) - (
                CASE
                    WHEN ((data_headers.datahdr % (data_headers.ma)::numeric) = (0)::numeric) THEN (data_headers.ma)::numeric
                    ELSE (data_headers.datahdr % (data_headers.ma)::numeric)
                END)::double precision)) / ((data_headers.bs - (20)::numeric))::double precision)) * (data_headers.bs)::double precision) AS expected_bytes,
            pg_class.reltoastrelid
           FROM ((data_headers
             JOIN pg_class ON ((data_headers.tablename = pg_class.relname)))
             JOIN pg_namespace ON (((pg_class.relnamespace = pg_namespace.oid) AND (data_headers.schemaname = pg_namespace.nspname))))
          WHERE (pg_class.relkind = 'r'::"char")
        ), estimates_with_toast AS (
         SELECT table_estimates.schemaname,
            table_estimates.tablename,
            true AS can_estimate,
            table_estimates.est_rows,
            (table_estimates.table_bytes + ((COALESCE(toast.relpages, 0))::numeric * table_estimates.bs)) AS table_bytes,
            (table_estimates.expected_bytes + (ceil((COALESCE(toast.reltuples, (0)::real) / (4)::double precision)) * (table_estimates.bs)::double precision)) AS expected_bytes
           FROM (table_estimates
             LEFT JOIN pg_class toast ON (((table_estimates.reltoastrelid = toast.oid) AND (toast.relkind = 't'::"char"))))
        ), table_estimates_plus AS (
         SELECT current_database() AS databasename,
            estimates_with_toast.schemaname,
            estimates_with_toast.tablename,
            estimates_with_toast.can_estimate,
            estimates_with_toast.est_rows,
                CASE
                    WHEN (estimates_with_toast.table_bytes > (0)::numeric) THEN estimates_with_toast.table_bytes
                    ELSE NULL::numeric
                END AS table_bytes,
                CASE
                    WHEN (estimates_with_toast.expected_bytes > (0)::double precision) THEN (estimates_with_toast.expected_bytes)::numeric
                    ELSE NULL::numeric
                END AS expected_bytes,
                CASE
                    WHEN ((estimates_with_toast.expected_bytes > (0)::double precision) AND (estimates_with_toast.table_bytes > (0)::numeric) AND (estimates_with_toast.expected_bytes <= (estimates_with_toast.table_bytes)::double precision)) THEN (((estimates_with_toast.table_bytes)::double precision - estimates_with_toast.expected_bytes))::numeric
                    ELSE (0)::numeric
                END AS bloat_bytes
           FROM estimates_with_toast
        UNION ALL
         SELECT current_database() AS databasename,
            no_stats.table_schema,
            no_stats.table_name,
            false AS bool,
            no_stats.est_rows,
            no_stats.table_size,
            NULL::numeric AS "numeric",
            NULL::numeric AS "numeric"
           FROM no_stats
        ), bloat_data AS (
         SELECT current_database() AS database_name,
            table_estimates_plus.schemaname AS schema_name,
            table_estimates_plus.tablename AS table_name,
            table_estimates_plus.can_estimate,
            table_estimates_plus.table_bytes,
            round((table_estimates_plus.table_bytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS table_mb,
            table_estimates_plus.expected_bytes,
            round((table_estimates_plus.expected_bytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS expected_mb,
            round(((table_estimates_plus.bloat_bytes * (100)::numeric) / table_estimates_plus.table_bytes)) AS pct_bloat,
            round((table_estimates_plus.bloat_bytes / ((1024)::numeric ^ (2)::numeric)), 2) AS mb_bloat,
            table_estimates_plus.est_rows
           FROM table_estimates_plus
        )
 SELECT bloat_data.database_name AS datname,
    bloat_data.schema_name AS nspname,
    bloat_data.table_name AS relname,
    bloat_data.est_rows,
    bloat_data.pct_bloat AS bloat_pct,
    (bloat_data.table_mb - bloat_data.mb_bloat) AS actual_mb,
    bloat_data.mb_bloat AS bloat_mb,
    bloat_data.table_mb AS total_mb
   FROM bloat_data
  WHERE bloat_data.can_estimate
  ORDER BY bloat_data.pct_bloat DESC;


ALTER TABLE monitor.pg_bloat_tables OWNER TO postgres;

--
-- Name: VIEW pg_bloat_tables; Type: COMMENT; Schema: monitor; Owner: postgres
--

COMMENT ON VIEW monitor.pg_bloat_tables IS 'monitor table bloat';


--
-- Name: v_bloat_indexes; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_bloat_indexes AS
 WITH btree_index_atts AS (
         SELECT pg_namespace.nspname,
            indexclass.relname AS index_name,
            indexclass.reltuples,
            indexclass.relpages,
            pg_index.indrelid,
            pg_index.indexrelid,
            indexclass.relam,
            tableclass.relname AS tablename,
            (regexp_split_to_table((pg_index.indkey)::text, ' '::text))::smallint AS attnum,
            pg_index.indexrelid AS index_oid
           FROM ((((pg_index
             JOIN pg_class indexclass ON ((pg_index.indexrelid = indexclass.oid)))
             JOIN pg_class tableclass ON ((pg_index.indrelid = tableclass.oid)))
             JOIN pg_namespace ON ((pg_namespace.oid = indexclass.relnamespace)))
             JOIN pg_am ON ((indexclass.relam = pg_am.oid)))
          WHERE ((pg_am.amname = 'btree'::name) AND (indexclass.relpages > 0))
        ), index_item_sizes AS (
         SELECT ind_atts.nspname,
            ind_atts.index_name,
            ind_atts.reltuples,
            ind_atts.relpages,
            ind_atts.relam,
            ind_atts.indrelid AS table_oid,
            ind_atts.index_oid,
            (current_setting('block_size'::text))::numeric AS bs,
            8 AS maxalign,
            24 AS pagehdr,
                CASE
                    WHEN (max(COALESCE(pg_stats.null_frac, (0)::real)) = (0)::double precision) THEN 2
                    ELSE 6
                END AS index_tuple_hdr,
            sum((((1)::double precision - COALESCE(pg_stats.null_frac, (0)::real)) * (COALESCE(pg_stats.avg_width, 1024))::double precision)) AS nulldatawidth
           FROM ((pg_attribute
             JOIN btree_index_atts ind_atts ON (((pg_attribute.attrelid = ind_atts.indexrelid) AND (pg_attribute.attnum = ind_atts.attnum))))
             JOIN pg_stats ON (((pg_stats.schemaname = ind_atts.nspname) AND (((pg_stats.tablename = ind_atts.tablename) AND ((pg_stats.attname)::text = pg_get_indexdef(pg_attribute.attrelid, (pg_attribute.attnum)::integer, true))) OR ((pg_stats.tablename = ind_atts.index_name) AND (pg_stats.attname = pg_attribute.attname))))))
          WHERE (pg_attribute.attnum > 0)
          GROUP BY ind_atts.nspname, ind_atts.index_name, ind_atts.reltuples, ind_atts.relpages, ind_atts.relam, ind_atts.indrelid, ind_atts.index_oid, (current_setting('block_size'::text))::numeric, 8::integer
        ), index_aligned_est AS (
         SELECT index_item_sizes.maxalign,
            index_item_sizes.bs,
            index_item_sizes.nspname,
            index_item_sizes.index_name,
            index_item_sizes.reltuples,
            index_item_sizes.relpages,
            index_item_sizes.relam,
            index_item_sizes.table_oid,
            index_item_sizes.index_oid,
            COALESCE(ceil((((index_item_sizes.reltuples * ((((((((6 + index_item_sizes.maxalign) -
                CASE
                    WHEN ((index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE (index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign)
                END))::double precision + index_item_sizes.nulldatawidth) + (index_item_sizes.maxalign)::double precision) - (
                CASE
                    WHEN (((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE ((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign)
                END)::double precision))::numeric)::double precision) / ((index_item_sizes.bs - (index_item_sizes.pagehdr)::numeric))::double precision) + (1)::double precision)), (0)::double precision) AS expected
           FROM index_item_sizes
        ), raw_bloat AS (
         SELECT current_database() AS dbname,
            index_aligned_est.nspname,
            pg_class.relname AS table_name,
            index_aligned_est.index_name,
            (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric) AS totalbytes,
            index_aligned_est.expected,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric)
                END AS wastedbytes,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (((index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric) * (100)::numeric) / (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric))
                END AS realbloat,
            pg_relation_size((index_aligned_est.table_oid)::regclass) AS table_bytes,
            stat.idx_scan AS index_scans
           FROM ((index_aligned_est
             JOIN pg_class ON ((pg_class.oid = index_aligned_est.table_oid)))
             JOIN pg_stat_user_indexes stat ON ((index_aligned_est.index_oid = stat.indexrelid)))
        ), format_bloat AS (
         SELECT raw_bloat.dbname AS database_name,
            raw_bloat.nspname AS schema_name,
            raw_bloat.table_name,
            raw_bloat.index_name,
            round(raw_bloat.realbloat) AS bloat_pct,
            round((raw_bloat.wastedbytes / (((1024)::double precision ^ (2)::double precision))::numeric)) AS bloat_mb,
            round((raw_bloat.totalbytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS index_mb,
            round(((raw_bloat.table_bytes)::numeric / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS table_mb,
            raw_bloat.index_scans
           FROM raw_bloat
        )
 SELECT format_bloat.database_name,
    format_bloat.schema_name,
    format_bloat.table_name,
    format_bloat.index_name,
    format_bloat.index_scans,
    format_bloat.bloat_pct,
    format_bloat.bloat_mb,
    format_bloat.index_mb,
    format_bloat.table_mb
   FROM format_bloat
  ORDER BY format_bloat.bloat_mb DESC;


ALTER TABLE monitor.v_bloat_indexes OWNER TO postgres;

--
-- Name: v_bloat_tables; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_bloat_tables AS
 WITH constants AS (
         SELECT (current_setting('block_size'::text))::numeric AS bs,
            23 AS hdr,
            8 AS ma
        ), no_stats AS (
         SELECT columns.table_schema,
            columns.table_name,
            (psut.n_live_tup)::numeric AS est_rows,
            (pg_table_size((psut.relid)::regclass))::numeric AS table_size
           FROM ((information_schema.columns
             JOIN pg_stat_user_tables psut ON ((((columns.table_schema)::name = psut.schemaname) AND ((columns.table_name)::name = psut.relname))))
             LEFT JOIN pg_stats ON ((((columns.table_schema)::name = pg_stats.schemaname) AND ((columns.table_name)::name = pg_stats.tablename) AND ((columns.column_name)::name = pg_stats.attname))))
          WHERE ((pg_stats.attname IS NULL) AND ((columns.table_schema)::text <> ALL (ARRAY[('pg_catalog'::character varying)::text, ('information_schema'::character varying)::text])))
          GROUP BY columns.table_schema, columns.table_name, psut.relid, psut.n_live_tup
        ), null_headers AS (
         SELECT ((constants.hdr + 1) + (sum(
                CASE
                    WHEN (pg_stats.null_frac <> (0)::double precision) THEN 1
                    ELSE 0
                END) / 8)) AS nullhdr,
            sum((((1)::double precision - pg_stats.null_frac) * (pg_stats.avg_width)::double precision)) AS datawidth,
            max(pg_stats.null_frac) AS maxfracsum,
            pg_stats.schemaname,
            pg_stats.tablename,
            constants.hdr,
            constants.ma,
            constants.bs
           FROM ((pg_stats
             CROSS JOIN constants)
             LEFT JOIN no_stats ON (((pg_stats.schemaname = (no_stats.table_schema)::name) AND (pg_stats.tablename = (no_stats.table_name)::name))))
          WHERE ((pg_stats.schemaname <> ALL (ARRAY['pg_catalog'::name, 'information_schema'::name])) AND (no_stats.table_name IS NULL) AND (EXISTS ( SELECT 1
                   FROM information_schema.columns
                  WHERE ((pg_stats.schemaname = (columns.table_schema)::name) AND (pg_stats.tablename = (columns.table_name)::name)))))
          GROUP BY pg_stats.schemaname, pg_stats.tablename, constants.hdr, constants.ma, constants.bs
        ), data_headers AS (
         SELECT null_headers.ma,
            null_headers.bs,
            null_headers.hdr,
            null_headers.schemaname,
            null_headers.tablename,
            ((null_headers.datawidth + (((null_headers.hdr + null_headers.ma) -
                CASE
                    WHEN ((null_headers.hdr % null_headers.ma) = 0) THEN null_headers.ma
                    ELSE (null_headers.hdr % null_headers.ma)
                END))::double precision))::numeric AS datahdr,
            (null_headers.maxfracsum * (((null_headers.nullhdr + null_headers.ma) -
                CASE
                    WHEN ((null_headers.nullhdr % (null_headers.ma)::bigint) = 0) THEN (null_headers.ma)::bigint
                    ELSE (null_headers.nullhdr % (null_headers.ma)::bigint)
                END))::double precision) AS nullhdr2
           FROM null_headers
        ), table_estimates AS (
         SELECT data_headers.schemaname,
            data_headers.tablename,
            data_headers.bs,
            (pg_class.reltuples)::numeric AS est_rows,
            ((pg_class.relpages)::numeric * data_headers.bs) AS table_bytes,
            (ceil(((pg_class.reltuples * (((((data_headers.datahdr)::double precision + data_headers.nullhdr2) + (4)::double precision) + (data_headers.ma)::double precision) - (
                CASE
                    WHEN ((data_headers.datahdr % (data_headers.ma)::numeric) = (0)::numeric) THEN (data_headers.ma)::numeric
                    ELSE (data_headers.datahdr % (data_headers.ma)::numeric)
                END)::double precision)) / ((data_headers.bs - (20)::numeric))::double precision)) * (data_headers.bs)::double precision) AS expected_bytes,
            pg_class.reltoastrelid
           FROM ((data_headers
             JOIN pg_class ON ((data_headers.tablename = pg_class.relname)))
             JOIN pg_namespace ON (((pg_class.relnamespace = pg_namespace.oid) AND (data_headers.schemaname = pg_namespace.nspname))))
          WHERE (pg_class.relkind = 'r'::"char")
        ), estimates_with_toast AS (
         SELECT table_estimates.schemaname,
            table_estimates.tablename,
            true AS can_estimate,
            table_estimates.est_rows,
            (table_estimates.table_bytes + ((COALESCE(toast.relpages, 0))::numeric * table_estimates.bs)) AS table_bytes,
            (table_estimates.expected_bytes + (ceil((COALESCE(toast.reltuples, (0)::real) / (4)::double precision)) * (table_estimates.bs)::double precision)) AS expected_bytes
           FROM (table_estimates
             LEFT JOIN pg_class toast ON (((table_estimates.reltoastrelid = toast.oid) AND (toast.relkind = 't'::"char"))))
        ), table_estimates_plus AS (
         SELECT current_database() AS databasename,
            estimates_with_toast.schemaname,
            estimates_with_toast.tablename,
            estimates_with_toast.can_estimate,
            estimates_with_toast.est_rows,
                CASE
                    WHEN (estimates_with_toast.table_bytes > (0)::numeric) THEN estimates_with_toast.table_bytes
                    ELSE NULL::numeric
                END AS table_bytes,
                CASE
                    WHEN (estimates_with_toast.expected_bytes > (0)::double precision) THEN (estimates_with_toast.expected_bytes)::numeric
                    ELSE NULL::numeric
                END AS expected_bytes,
                CASE
                    WHEN ((estimates_with_toast.expected_bytes > (0)::double precision) AND (estimates_with_toast.table_bytes > (0)::numeric) AND (estimates_with_toast.expected_bytes <= (estimates_with_toast.table_bytes)::double precision)) THEN (((estimates_with_toast.table_bytes)::double precision - estimates_with_toast.expected_bytes))::numeric
                    ELSE (0)::numeric
                END AS bloat_bytes
           FROM estimates_with_toast
        UNION ALL
         SELECT current_database() AS databasename,
            no_stats.table_schema,
            no_stats.table_name,
            false AS bool,
            no_stats.est_rows,
            no_stats.table_size,
            NULL::numeric AS "numeric",
            NULL::numeric AS "numeric"
           FROM no_stats
        ), bloat_data AS (
         SELECT current_database() AS database_name,
            table_estimates_plus.schemaname AS schema_name,
            table_estimates_plus.tablename AS table_name,
            table_estimates_plus.can_estimate,
            table_estimates_plus.table_bytes,
            round((table_estimates_plus.table_bytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS table_mb,
            table_estimates_plus.expected_bytes,
            round((table_estimates_plus.expected_bytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS expected_mb,
            round(((table_estimates_plus.bloat_bytes * (100)::numeric) / table_estimates_plus.table_bytes)) AS pct_bloat,
            round((table_estimates_plus.bloat_bytes / ((1024)::numeric ^ (2)::numeric)), 2) AS mb_bloat,
            table_estimates_plus.est_rows
           FROM table_estimates_plus
        )
 SELECT bloat_data.database_name,
    bloat_data.schema_name,
    bloat_data.table_name,
    bloat_data.pct_bloat,
    bloat_data.mb_bloat,
    bloat_data.table_mb,
    bloat_data.can_estimate,
    bloat_data.est_rows
   FROM bloat_data
  ORDER BY bloat_data.pct_bloat DESC;


ALTER TABLE monitor.v_bloat_tables OWNER TO postgres;

--
-- Name: v_dupe_indexes; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_dupe_indexes AS
 WITH index_cols_ord AS (
         SELECT pg_attribute.attrelid,
            pg_attribute.attnum,
            pg_attribute.attname
           FROM (pg_attribute
             JOIN pg_index ON ((pg_index.indexrelid = pg_attribute.attrelid)))
          WHERE (pg_index.indkey[0] > 0)
          ORDER BY pg_attribute.attrelid, pg_attribute.attnum
        ), index_col_list AS (
         SELECT index_cols_ord.attrelid,
            array_agg(index_cols_ord.attname) AS cols
           FROM index_cols_ord
          GROUP BY index_cols_ord.attrelid
        ), dup_natts AS (
         SELECT ind.indrelid,
            ind.indexrelid
           FROM pg_index ind
          WHERE (EXISTS ( SELECT 1
                   FROM pg_index ind2
                  WHERE ((ind.indrelid = ind2.indrelid) AND ((ind.indkey @> ind2.indkey) OR (ind.indkey <@ ind2.indkey)) AND (ind.indkey[0] = ind2.indkey[0]) AND (ind.indkey <> ind2.indkey) AND (ind.indexrelid <> ind2.indexrelid))))
        )
 SELECT userdex.schemaname AS schema_name,
    userdex.relname AS table_name,
    userdex.indexrelname AS index_name,
    array_to_string(index_col_list.cols, ', '::text) AS index_cols,
    pg_indexes.indexdef,
    userdex.idx_scan AS index_scans
   FROM (((pg_stat_user_indexes userdex
     JOIN index_col_list ON ((index_col_list.attrelid = userdex.indexrelid)))
     JOIN dup_natts ON ((userdex.indexrelid = dup_natts.indexrelid)))
     JOIN pg_indexes ON (((userdex.schemaname = pg_indexes.schemaname) AND (userdex.indexrelname = pg_indexes.indexname))))
  ORDER BY userdex.schemaname, userdex.relname, index_col_list.cols, userdex.indexrelname;


ALTER TABLE monitor.v_dupe_indexes OWNER TO postgres;

--
-- Name: v_function_stats; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_function_stats AS
 WITH total AS (
         SELECT (sum(pg_stat_user_functions_1.total_time))::bigint AS total_agg
           FROM pg_stat_user_functions pg_stat_user_functions_1
        )
 SELECT pg_stat_user_functions.funcname AS function_name,
    sum(pg_stat_user_functions.calls) AS calls,
    (sum(pg_stat_user_functions.total_time))::bigint AS total_time,
    (sum(pg_stat_user_functions.self_time))::bigint AS self_call_time,
    (sum(pg_stat_user_functions.total_time) / (sum(pg_stat_user_functions.calls))::double precision) AS avg_time,
    (((100)::double precision * sum(pg_stat_user_functions.total_time)) / (( SELECT total.total_agg
           FROM total))::double precision) AS pct_functions
   FROM pg_stat_user_functions
  GROUP BY pg_stat_user_functions.funcname
  ORDER BY ((sum(pg_stat_user_functions.total_time))::bigint) DESC;


ALTER TABLE monitor.v_function_stats OWNER TO postgres;

--
-- Name: v_no_stats_table; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_no_stats_table AS
 SELECT columns.table_schema,
    columns.table_name,
    (pg_class.relpages = 0) AS is_empty,
    ((psut.relname IS NULL) OR ((psut.last_analyze IS NULL) AND (psut.last_autoanalyze IS NULL))) AS never_analyzed,
    array_agg((columns.column_name)::text) AS no_stats_columns
   FROM ((((information_schema.columns
     JOIN pg_class ON ((((columns.table_name)::name = pg_class.relname) AND (pg_class.relkind = 'r'::"char"))))
     JOIN pg_namespace ON (((pg_class.relnamespace = pg_namespace.oid) AND (pg_namespace.nspname = (columns.table_schema)::name))))
     LEFT JOIN pg_stats ON ((((columns.table_schema)::name = pg_stats.schemaname) AND ((columns.table_name)::name = pg_stats.tablename) AND ((columns.column_name)::name = pg_stats.attname))))
     LEFT JOIN pg_stat_user_tables psut ON ((((columns.table_schema)::name = psut.schemaname) AND ((columns.table_name)::name = psut.relname))))
  WHERE ((pg_stats.attname IS NULL) AND ((columns.table_schema)::text <> ALL (ARRAY[('pg_catalog'::character varying)::text, ('information_schema'::character varying)::text])))
  GROUP BY columns.table_schema, columns.table_name, pg_class.relpages, psut.relname, psut.last_analyze, psut.last_autoanalyze;


ALTER TABLE monitor.v_no_stats_table OWNER TO postgres;

--
-- Name: v_pgstat_io; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_pgstat_io AS
 SELECT pg_stat_user_tables.schemaname,
    pg_stat_user_tables.relname,
    ((((COALESCE(pg_stat_user_tables.seq_tup_read, (0)::bigint) + COALESCE(pg_stat_user_tables.idx_tup_fetch, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_ins, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_upd, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_del, (0)::bigint)) AS total_tuple,
    (COALESCE(pg_stat_user_tables.seq_tup_read, (0)::bigint) + COALESCE(pg_stat_user_tables.idx_tup_fetch, (0)::bigint)) AS total_select,
    COALESCE(pg_stat_user_tables.n_tup_ins, (0)::bigint) AS total_insert,
    COALESCE(pg_stat_user_tables.n_tup_upd, (0)::bigint) AS total_update,
    COALESCE(pg_stat_user_tables.n_tup_del, (0)::bigint) AS total_delete
   FROM pg_stat_user_tables
  ORDER BY ((((COALESCE(pg_stat_user_tables.seq_tup_read, (0)::bigint) + COALESCE(pg_stat_user_tables.idx_tup_fetch, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_ins, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_upd, (0)::bigint)) + COALESCE(pg_stat_user_tables.n_tup_del, (0)::bigint)) DESC;


ALTER TABLE monitor.v_pgstat_io OWNER TO postgres;

--
-- Name: v_relation_size; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_relation_size AS
 SELECT c.relkind,
    n.nspname AS schema_name,
    c.relname AS relation_name,
        CASE
            WHEN (c.relkind = 'i'::"char") THEN 'index'::text
            WHEN (c.relkind = 'r'::"char") THEN 'ordinary table'::text
            WHEN (c.relkind = 'S'::"char") THEN 'sequence'::text
            WHEN (c.relkind = 'v'::"char") THEN 'view'::text
            WHEN (c.relkind = 'm'::"char") THEN 'materialized view'::text
            WHEN (c.relkind = 'c'::"char") THEN 'composite type'::text
            WHEN (c.relkind = 't'::"char") THEN 'TOAST table'::text
            WHEN (c.relkind = 'f'::"char") THEN 'foreign table'::text
            ELSE NULL::text
        END AS relation_type,
        CASE
            WHEN (c.relkind = 'r'::"char") THEN pg_size_pretty(pg_table_size((c.oid)::regclass))
            ELSE pg_size_pretty(pg_total_relation_size((c.oid)::regclass))
        END AS relation_size,
    pg_size_pretty(pg_total_relation_size((c.oid)::regclass)) AS total_size
   FROM (pg_class c
     LEFT JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
  WHERE ((n.nspname <> ALL (ARRAY['pg_catalog'::name, 'information_schema'::name])) AND (n.nspname !~ '^pg_toast'::text))
  ORDER BY (pg_total_relation_size((c.oid)::regclass)) DESC;


ALTER TABLE monitor.v_relation_size OWNER TO postgres;

--
-- Name: v_repeated_indexes; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_repeated_indexes AS
 SELECT sub.key,
    sub.indexrelid AS idx_oid,
    sub.schemaname AS schema_name,
    sub.tablename AS table_name,
    sub.indexname AS idx_name,
    sub.indisprimary,
    sub.idx_scan,
    sub.idx_tup_read,
    sub.idx_tup_fetch,
    sub.idx_size
   FROM ( SELECT pi.indexrelid,
            pi.indisprimary,
            pis.schemaname,
            pis.tablename,
            pis.indexname,
            psui.idx_scan,
            psui.idx_tup_read,
            psui.idx_tup_fetch,
            pg_size_pretty(pg_relation_size((pi.indexrelid)::regclass)) AS idx_size,
            (((((pi.indrelid)::text || (pi.indclass)::text) || (pi.indkey)::text) || COALESCE((pi.indexprs)::text, ''::text)) || COALESCE((pi.indpred)::text, ''::text)) AS key,
            count(*) OVER (PARTITION BY (((((pi.indrelid)::text || (pi.indclass)::text) || (pi.indkey)::text) || COALESCE((pi.indexprs)::text, ''::text)) || COALESCE((pi.indpred)::text, ''::text))) AS n_rpt_idx
           FROM pg_index pi,
            pg_indexes pis,
            pg_stat_user_indexes psui
          WHERE ((((pi.indexrelid)::regclass)::text = (pis.indexname)::text) AND (pi.indexrelid = psui.indexrelid) AND (pis.schemaname <> ALL (ARRAY['pg_catalog'::name, 'information_schema'::name])))) sub
  WHERE (sub.n_rpt_idx > 1)
  ORDER BY sub.idx_size DESC;


ALTER TABLE monitor.v_repeated_indexes OWNER TO postgres;

--
-- Name: v_repl_stats; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_repl_stats AS
 SELECT repl.pid,
    repl.usesysid,
    repl.usename,
    repl.application_name,
    repl.client_addr,
    repl.client_hostname,
    repl.client_port,
    repl.backend_start,
    repl.state,
    repl.sent_lsn,
    repl.write_lsn,
    repl.flush_lsn,
    repl.replay_lsn,
    repl.sync_priority,
    repl.sync_state,
    pg_size_pretty(pg_wal_lsn_diff(repl.sent_lsn, repl.write_lsn)) AS network_delay,
    pg_size_pretty(pg_wal_lsn_diff(repl.write_lsn, repl.flush_lsn)) AS slave_write,
    pg_size_pretty(pg_wal_lsn_diff(repl.flush_lsn, repl.replay_lsn)) AS slave_replay,
        CASE
            WHEN pg_is_in_recovery() THEN pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), repl.replay_lsn))
            ELSE pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), repl.replay_lsn))
        END AS total_lag
   FROM pg_stat_replication repl
  ORDER BY
        CASE
            WHEN pg_is_in_recovery() THEN pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), repl.replay_lsn))
            ELSE pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), repl.replay_lsn))
        END DESC;


ALTER TABLE monitor.v_repl_stats OWNER TO postgres;

--
-- Name: v_stat_activity; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_stat_activity AS
 SELECT pg_stat_activity.datid,
    pg_stat_activity.datname,
    pg_stat_activity.pid,
    pg_stat_activity.usesysid,
    pg_stat_activity.usename,
    pg_stat_activity.application_name,
    pg_stat_activity.client_addr,
    pg_stat_activity.client_hostname,
    pg_stat_activity.client_port,
    pg_stat_activity.backend_start,
    pg_stat_activity.xact_start,
    pg_stat_activity.query_start,
    pg_stat_activity.state_change,
    pg_stat_activity.wait_event,
    pg_stat_activity.state,
    (now() - pg_stat_activity.query_start) AS runtime,
    regexp_replace(pg_stat_activity.query, '[
	 ]+'::text, ' '::text, 'ig'::text) AS query
   FROM pg_stat_activity
  WHERE (pg_stat_activity.pid <> pg_backend_pid())
  ORDER BY (now() - pg_stat_activity.query_start) DESC;


ALTER TABLE monitor.v_stat_activity OWNER TO postgres;

--
-- Name: v_statements; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_statements AS
 SELECT s.calls,
    (s.total_time / (1000)::double precision) AS total_time,
    ((s.total_time / (s.calls)::double precision) / (1000)::double precision) AS avg_time,
    regexp_replace(s.query, '[
	 ]+'::text, ' '::text, 'ig'::text) AS query
   FROM monitor.pg_stat_statements s
  WHERE ((s.query <> ALL (ARRAY['SELECT $1;'::text, 'BEGIN'::text, 'COMMIT'::text, 'ROLLBACK'::text, 'DISCARD ALL;'::text])) AND (s.query !~* 'vacuum'::text) AND (s.query !~* 'analyze'::text))
  ORDER BY ((s.total_time / (s.calls)::double precision) / (1000)::double precision) DESC;


ALTER TABLE monitor.v_statements OWNER TO postgres;

--
-- Name: v_streaming_timedelay; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_streaming_timedelay AS
 SELECT
        CASE
            WHEN (pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()) THEN (0)::double precision
            ELSE date_part('epoch'::text, (now() - pg_last_xact_replay_timestamp()))
        END AS time_delay;


ALTER TABLE monitor.v_streaming_timedelay OWNER TO postgres;

--
-- Name: v_vacuum_needed; Type: VIEW; Schema: monitor; Owner: postgres
--

CREATE VIEW monitor.v_vacuum_needed AS
 SELECT av.nspname AS schema_name,
    av.relname AS table_name,
    av.n_tup_ins,
    av.n_tup_upd,
    av.n_tup_del,
    av.hot_update_ratio,
    av.n_live_tup,
    av.n_dead_tup,
    av.reltuples,
    av.av_threshold,
    av.last_vacuum,
    av.last_analyze,
    ((av.n_dead_tup)::double precision > av.av_threshold) AS av_needed,
        CASE
            WHEN (av.reltuples > (0)::double precision) THEN round((((100.0 * (av.n_dead_tup)::numeric))::double precision / av.reltuples))
            ELSE (0)::double precision
        END AS pct_dead
   FROM ( SELECT n.nspname,
            c.relname,
            pg_stat_get_tuples_inserted(c.oid) AS n_tup_ins,
            pg_stat_get_tuples_updated(c.oid) AS n_tup_upd,
            pg_stat_get_tuples_deleted(c.oid) AS n_tup_del,
                CASE
                    WHEN (pg_stat_get_tuples_updated(c.oid) > 0) THEN ((pg_stat_get_tuples_hot_updated(c.oid))::real / (pg_stat_get_tuples_updated(c.oid))::double precision)
                    ELSE (0)::double precision
                END AS hot_update_ratio,
            pg_stat_get_live_tuples(c.oid) AS n_live_tup,
            pg_stat_get_dead_tuples(c.oid) AS n_dead_tup,
            c.reltuples,
            round((((current_setting('autovacuum_vacuum_threshold'::text))::integer)::double precision + (((current_setting('autovacuum_vacuum_scale_factor'::text))::numeric)::double precision * c.reltuples))) AS av_threshold,
            date_trunc('minute'::text, GREATEST(pg_stat_get_last_vacuum_time(c.oid), pg_stat_get_last_autovacuum_time(c.oid))) AS last_vacuum,
            date_trunc('minute'::text, GREATEST(pg_stat_get_last_analyze_time(c.oid), pg_stat_get_last_analyze_time(c.oid))) AS last_analyze
           FROM (pg_class c
             LEFT JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
          WHERE (((c.relkind)::text = ANY (ARRAY['r'::text, 't'::text])) AND (n.nspname !~ '^pg_toast'::text))) av
  ORDER BY ((av.n_dead_tup)::double precision > av.av_threshold) DESC, av.n_dead_tup DESC;


ALTER TABLE monitor.v_vacuum_needed OWNER TO postgres;

GRANT USAGE ON SCHEMA monitor TO "dbuser_monitor" ;
GRANT SELECT ON ALL TABLES IN SCHEMA monitor TO "dbuser_monitor" ;
ALTER ROLE dbuser_monitor SET search_path TO monitor ;
grant all on all functions in schema monitor TO "dbuser_monitor" ;
--
-- PostgreSQL database dump complete
--

