/* Engine Variables */
set global subprocess_ec2_metadata_timeout_ms = 1000;

/* Logistics Database and Table Schema */
DROP DATABASE IF EXISTS logistics;
CREATE DATABASE IF NOT EXISTS logistics;
USE logistics;
-- set global default_table_type="rowstore";
-- the packages table stores one row per package
CREATE TABLE packages (
    -- packageid is a unique identifier for this package
    -- format: UUID stored in its canonical text representation (32 hexadecimal characters and 4 hyphens)
    packageid CHAR(36) NOT NULL,

    -- simulatorid is a unique identifier for the simulator process which manages this package
    simulatorid TEXT NOT NULL,

    -- marks when the package was received
    received DATETIME NOT NULL,

    -- marks when the package is expected to be delivered
    delivery_estimate DATETIME NOT NULL,

    -- origin_locationid specifies the location where the package was originally
    -- received
    origin_locationid BIGINT NOT NULL,

    -- destination_locationid specifies the package's destination location
    destination_locationid BIGINT NOT NULL,

    -- the shipping method selected
    -- standard packages are delivered using the slowest method at each point
    -- express packages are delivered using the fastest method at each point
    method ENUM ('standard', 'express') NOT NULL,

    -- marks when the row was created
    created DATETIME NOT NULL DEFAULT NOW(),

    KEY (received) USING CLUSTERED COLUMNSTORE,
    SHARD (packageid),
    UNIQUE KEY (packageid) USING HASH
);

CREATE ROWSTORE REFERENCE TABLE locations (
    locationid BIGINT NOT NULL,

    -- each location in our distribution network is either a hub or a pickup-dropoff point
    -- a hub is usually located in larger cities and acts as both a pickup-dropoff and transit location
    -- a point only supports pickup or dropoff - it can't handle a large package volume
    kind ENUM ('hub', 'point') NOT NULL,

    -- useful metadata for queries
    city TEXT NOT NULL,
    country TEXT NOT NULL,
    city_population DECIMAL(20,0) NOT NULL,

    lonlat GEOGRAPHYPOINT NOT NULL,

    PRIMARY KEY (locationid),
    INDEX (lonlat)
);

CREATE TABLE package_transitions (
    packageid CHAR(36) NOT NULL,

    -- each package transition is assigned a strictly monotonically increasing sequence number
    seq INT NOT NULL,

    -- the location of the package where this transition occurred
    locationid BIGINT NOT NULL,

    -- the location of the next transition for this package
    -- currently only used for departure scans
    next_locationid BIGINT,

    -- when did this transition happen
    recorded DATETIME NOT NULL,

    -- marks when the row was created
    created DATETIME NOT NULL DEFAULT NOW(),

    kind ENUM (
        -- arrival scan means the package was received
        'arrival_scan',
        -- departure scan means the package is enroute to another location
        'departure_scan',
        -- delivered means the package was successfully delivered
        'delivered'
    ) NOT NULL,

    KEY (recorded) USING CLUSTERED COLUMNSTORE,
    KEY (packageid) USING HASH,
    SHARD (packageid)
);

-- this table contains the current state of each package
-- rows are deleted from this table once the corresponding package is delivered
CREATE ROWSTORE TABLE package_states (
    packageid CHAR(36) NOT NULL,
    seq INT NOT NULL,
    locationid BIGINT NOT NULL,
    next_locationid BIGINT,
    recorded DATETIME NOT NULL,

    kind ENUM ('in_transit', 'at_rest') NOT NULL,

    PRIMARY KEY (packageid),
    INDEX (recorded),
    INDEX (kind)
);

DELIMITER //

CREATE OR REPLACE PROCEDURE process_transitions(batch QUERY(
    packageid CHAR(36) NOT NULL,
    seq INT NOT NULL,
    locationid BIGINT NOT NULL,
    next_locationid BIGINT,
    recorded DATETIME NOT NULL,
    kind TEXT NOT NULL
))
AS
BEGIN
    REPLACE INTO package_transitions (packageid, seq, locationid, next_locationid, recorded, kind)
    SELECT * FROM batch;

    INSERT INTO package_states (packageid, seq, locationid, next_locationid, recorded, kind)
    SELECT
        packageid,
        seq,
        locationid,
        next_locationid,
        recorded,
        statekind AS kind
    FROM (
        SELECT *, CASE
            WHEN kind = "arrival_scan" THEN "at_rest"
            WHEN kind = "departure_scan" THEN "in_transit"
        END AS statekind
        FROM batch
    ) batch
    WHERE batch.kind != "delivered"
    ON DUPLICATE KEY UPDATE
        seq = IF(VALUES(seq) > package_states.seq, VALUES(seq), package_states.seq),
        locationid = IF(VALUES(seq) > package_states.seq, VALUES(locationid), package_states.locationid),
        next_locationid = IF(VALUES(seq) > package_states.seq, VALUES(next_locationid), package_states.next_locationid),
        recorded = IF(VALUES(seq) > package_states.seq, VALUES(recorded), package_states.recorded),
        kind = IF(VALUES(seq) > package_states.seq, VALUES(kind), package_states.kind);

    DELETE package_states
    FROM package_states JOIN batch
    WHERE
        package_states.packageid = batch.packageid
        AND batch.kind = "delivered";

END //

DELIMITER ;

/* TPC-H Database and Table Schemas */
DROP DATABASE IF EXISTS order_mgt;
CREATE DATABASE IF NOT EXISTS order_mgt;
USE order_mgt;
-- TPC-H Table Schemas
SELECT "INFO: Creating customer table...";
CREATE TABLE `customer` (
 `c_custkey` int(11) NOT NULL,
 `c_name` varchar(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `c_address` varchar(40) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `c_nationkey` int(11) NOT NULL,
 `c_phone` char(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `c_acctbal` decimal(15,2) NOT NULL,
 `c_mktsegment` char(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `c_comment` varchar(117) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`c_custkey`) UNENFORCED RELY,
 SHARD KEY (`c_custkey`) using clustered columnstore
);

SELECT "INFO: Creating lineitem table...";
CREATE TABLE `lineitem` (
 `l_orderkey` bigint(11) NOT NULL,
 `l_partkey` int(11) NOT NULL,
 `l_suppkey` int(11) NOT NULL,
 `l_linenumber` int(11) NOT NULL,
 `l_quantity` decimal(15,2) NOT NULL,
 `l_extendedprice` decimal(15,2) NOT NULL,
 `l_discount` decimal(15,2) NOT NULL,
 `l_tax` decimal(15,2) NOT NULL,
 `l_returnflag` char(1) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `l_linestatus` char(1) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `l_shipdate` date NOT NULL,
 `l_commitdate` date NOT NULL,
 `l_receiptdate` date NOT NULL,
 `l_shipinstruct` char(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `l_shipmode` char(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `l_comment` varchar(44) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`l_orderkey`, `l_linenumber`) UNENFORCED RELY ,
 SHARD KEY (`l_orderkey`) using clustered columnstore
);

SELECT "INFO: Creating nation table...";
CREATE TABLE `nation` (
 `n_nationkey` int(11) NOT NULL,
 `n_name` char(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `n_regionkey` int(11) NOT NULL,
 `n_comment` varchar(152) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`n_nationkey`) UNENFORCED RELY,
 SHARD KEY (`n_nationkey`) using clustered columnstore
);
 
SELECT "INFO: Creating orders table...";
CREATE TABLE `orders` (
 `o_orderkey` bigint(11) NOT NULL,
 `o_custkey` int(11) NOT NULL,
 `o_orderstatus` char(1) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `o_totalprice` decimal(15,2) NOT NULL,
 `o_orderdate` date NOT NULL,
 `o_orderpriority` char(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `o_clerk` char(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `o_shippriority` int(11) NOT NULL,
 `o_comment` varchar(79) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`o_orderkey`) UNENFORCED RELY,
 SHARD KEY (`o_orderkey`) using clustered columnstore
);
 
SELECT "INFO: Creating part table...";
CREATE TABLE `part` (
 `p_partkey` int(11) NOT NULL,
 `p_name` varchar(55) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `p_mfgr` char(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `p_brand` char(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `p_type` varchar(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `p_size` int(11) NOT NULL,
 `p_container` char(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `p_retailprice` decimal(15,2) NOT NULL,
 `p_comment` varchar(23) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`p_partkey`) UNENFORCED RELY,
 SHARD KEY (`p_partkey`) using clustered columnstore
);
 
SELECT "INFO: Creating partsupp table...";
CREATE TABLE `partsupp` (
 `ps_partkey` int(11) NOT NULL,
 `ps_suppkey` int(11) NOT NULL,
 `ps_availqty` int(11) NOT NULL,
 `ps_supplycost` decimal(15,2) NOT NULL,
 `ps_comment` varchar(199) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`ps_partkey`,`ps_suppkey`) UNENFORCED RELY,
 SHARD KEY(`ps_partkey`),
 KEY (`ps_partkey`,`ps_suppkey`) using clustered columnstore
);

SELECT "INFO: Creating region table...";
CREATE TABLE `region` (
 `r_regionkey` int(11) NOT NULL,
 `r_name` char(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `r_comment` varchar(152) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`r_regionkey`) UNENFORCED RELY,
 SHARD KEY (`r_regionkey`) using clustered columnstore
);

SELECT "INFO: Creating supplier table...";
CREATE TABLE `supplier` (
 `s_suppkey` int(11) NOT NULL,
 `s_name` char(25) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `s_address` varchar(40) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `s_nationkey` int(11) NOT NULL,
 `s_phone` char(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 `s_acctbal` decimal(15,2) NOT NULL,
 `s_comment` varchar(101) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,
 UNIQUE KEY pk (`s_suppkey`) UNENFORCED RELY,
 SHARD KEY (`s_suppkey`) USING CLUSTERED COLUMNSTORE
);

/* Conection Links */
USE order_mgt;
CREATE LINK minio AS S3
CREDENTIALS '{
    "aws_access_key_id": "root",
    "aws_secret_access_key": "SingleStore1!"
}'
CONFIG '{
    "endpoint_url": "http://{{ minio_url }}"
}';

USE logistics;
CREATE LINK minio AS S3
CREDENTIALS '{
    "aws_access_key_id": "root",
    "aws_secret_access_key": "SingleStore1!"
}'
CONFIG '{
    "endpoint_url": "http://{{ minio_url }}"
}';

CREATE LINK redpanda AS KAFKA
CONFIG '{
  "sasl.mechanism": "PLAINTEXT",
  "security.protocol": "PLAINTEXT"
}'
CREDENTIALS '{}';

/* Pipelines */
USE logistics;

-- we use this cities database to dynamically generate locations
-- cities with populations > 1,000,000 become hubs, the rest become points
CREATE OR REPLACE PIPELINE worldcities
AS LOAD DATA LINK minio 'simplemaps/worldcities.csv'
SKIP DUPLICATE KEY ERRORS
INTO TABLE locations
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(city, @, @lat, @lon, country, @, @, @, @, @population, locationid)
SET
    -- data is a bit messy - lets assume 0 people means 100 people
    city_population = IF(@population = 0, 100, @population),
    kind = IF(@population > 1000000, "hub", "point"),
    lonlat = CONCAT('POINT(', @lon, ' ', @lat, ')')
;
START PIPELINE worldcities FOREGROUND;

CREATE OR REPLACE PIPELINE packages
AS LOAD DATA KAFKA '{{ kafkaHost }}/packages'
CONFIG '{
  "sasl.mechanism": "PLAINTEXT",
  "security.protocol": "PLAINTEXT"
}'
CREDENTIALS '{}'
SKIP DUPLICATE KEY ERRORS
INTO TABLE packages
FORMAT AVRO (
    packageid <- PackageID,
    simulatorid <- SimulatorID,
    @received <- Received,
    @delivery_estimate <- DeliveryEstimate,
    origin_locationid <- OriginLocationID,
    destination_locationid <- DestinationLocationID,
    method <- Method
)
SCHEMA '{
    "type": "record",
    "name": "Package",
    "fields": [
        { "name": "PackageID", "type": { "type": "string", "logicalType": "uuid" } },
        { "name": "SimulatorID", "type": "string" },
        { "name": "Received", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "DeliveryEstimate", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "OriginLocationID", "type": "long" },
        { "name": "DestinationLocationID", "type": "long" },
        { "name": "Method", "type": { "name": "Method", "type": "enum", "symbols": [
            "standard", "express"
        ] } }
    ]
}'
SET
    received = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@received / 1000) SECOND),
    delivery_estimate = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@delivery_estimate / 1000) SECOND);

CREATE OR REPLACE PIPELINE transitions
AS LOAD DATA KAFKA '{{ kafkaHost }}/transitions'
CONFIG '{
  "sasl.mechanism": "PLAINTEXT",
  "security.protocol": "PLAINTEXT"
}'
CREDENTIALS '{}'
INTO PROCEDURE process_transitions
FORMAT AVRO (
    packageid <- PackageID,
    seq <- Seq,
    locationid <- LocationID,
    next_locationid <- NextLocationID,
    @recorded <- Recorded,
    kind <- Kind
)
SCHEMA '{
    "type": "record",
    "name": "PackageTransition",
    "fields": [
        { "name": "PackageID", "type": { "type": "string", "logicalType": "uuid" } },
        { "name": "Seq", "type": "int" },
        { "name": "LocationID", "type": "long" },
        { "name": "NextLocationID", "type": ["null", "long"] },
        { "name": "Recorded", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "Kind", "type": { "name": "Kind", "type": "enum", "symbols": [
            "arrival_scan", "departure_scan", "delivered"
        ] } }
    ]
}'
SET
    recorded = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@recorded / 1000) SECOND);

USE order_mgt;
SELECT "INFO: Creating S3 Pipelines...";
CREATE OR REPLACE PIPELINE order_mgmt_lineitem
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/lineitem/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE lineitem (
    l_orderkey,
    l_partkey,
    l_suppkey,
    l_linenumber,
    l_quantity,
    l_extendedprice,
    l_discount,
    l_tax,
    l_returnflag,
    l_linestatus,
    @l_shipdate,
    @l_commitdate,
    @l_receiptdate,
    l_shipinstruct,
    l_shipmode,
    l_comment
  )
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n'
  SET
    l_commitdate = TO_DATE((CURRENT_TIMESTAMP() - INTERVAL RAND()*365*2 DAY), 'YYYY-MM-DD'),
    l_shipdate = TO_DATE((CURRENT_TIMESTAMP() - INTERVAL RAND()*365*2 DAY), 'YYYY-MM-DD'),
    l_receiptdate = TO_DATE((CURRENT_TIMESTAMP() - INTERVAL RAND()*365*2 DAY), 'YYYY-MM-DD')
;

CREATE OR REPLACE PIPELINE order_mgmt_customer
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/customer/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE customer
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';

CREATE OR REPLACE PIPELINE order_mgmt_nation
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/nation/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE nation
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';
 
CREATE OR REPLACE PIPELINE order_mgmt_orders
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/orders/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE orders (
    o_orderkey,
    o_custkey,
    o_orderstatus,
    o_totalprice,
    @o_orderdate,
    o_orderpriority,
    o_clerk,
    o_shippriority,
    o_comment
  )
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n'
  SET
    o_orderdate = TO_DATE(DATE_SUB(CURRENT_TIMESTAMP(), INTERVAL RAND()*365*3 DAY), 'YYYY-MM-DD');
 
CREATE OR REPLACE PIPELINE order_mgmt_part
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/part/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE part
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';
 
CREATE OR REPLACE PIPELINE order_mgmt_partsupp
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/partsupp/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE partsupp
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';
 
CREATE OR REPLACE PIPELINE order_mgmt_region
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/region/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE region
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';
 
CREATE OR REPLACE PIPELINE order_mgmt_supplier
  AS LOAD DATA S3 'memsql-tpch-dataset/sf_100/supplier/'
  CONFIG '{"region":"us-east-1"}'
  SKIP DUPLICATE KEY ERRORS
  INTO TABLE supplier
  FIELDS TERMINATED BY '|'
  LINES TERMINATED BY '|\n';

CREATE OR REPLACE PIPELINE kafka_orders
AS LOAD DATA KAFKA '{{ kafkaHost }}/tpch'
CONFIG '{
  "sasl.mechanism": "PLAINTEXT",
  "security.protocol": "PLAINTEXT"
}'
CREDENTIALS '{}'
INTO TABLE orders
FORMAT JSON (
    o_orderkey <- o_orderkey,
    o_custkey <- o_custkey,
    o_orderstatus <- o_orderstatus,
    o_totalprice <- o_totalprice,
    o_orderdate <- o_orderdate,
    o_orderpriority <- o_orderpriority,
    @v_clerk <- o_clerk,
    o_shippriority <- o_shippriority,
    o_comment <- o_comment
)
SET
    o_clerk = SUBSTRING(@v_clerk, 1, 10);

CREATE OR REPLACE PIPELINE kafka_lineitem
AS LOAD DATA KAFKA '{{ kafkaHost }}/tpch'
CONFIG '{
  "sasl.mechanism": "PLAINTEXT",
  "security.protocol": "PLAINTEXT"
}'
CREDENTIALS '{}'
INTO TABLE lineitem
FORMAT JSON (
    l_orderkey <- lineitems::l_orderkey,
    l_partkey <- lineitems::l_partkey,
    l_suppkey <- lineitems::l_suppkey,
    l_linenumber <- lineitems::l_linenumber,
    l_quantity <- lineitems::l_quantity,
    l_extendedprice <- lineitems::l_extendedprice,
    l_discount <- lineitems::l_discount,
    l_tax <- lineitems::l_tax,
    l_returnflag <- lineitems::l_returnflag,
    l_linestatus <- lineitems::l_linestatus,
    l_shipdate <- lineitems::l_shipdate,
    l_commitdate <- lineitems::l_commitdate,
    l_receiptdate <- lineitems::l_receiptdate,
    l_shipinstruct <- lineitems::l_shipinstruct,
    l_shipmode <- lineitems::l_shipmode,
    @v_comment <- lineitems::l_comment
)
SET
    l_comment = SUBSTRING(@v_comment, 1, 44);

/* Views */
CREATE VIEW `customer_view` AS
SELECT `orders`.`o_orderkey`   AS `ORDER id`,
       `customer`.`c_name`     AS `customer NAME`,
       `customer`.`c_acctbal`  AS `account balance`,
       `nation`.`n_name`       AS `country`,
       `orders`.`o_clerk`      AS `sales associate`,
       `orders`.`o_orderdate`  AS `ORDER date`,
       `orders`.`o_totalprice` AS `total price`
FROM   (`customer` AS `customer` , `orders` AS `orders` , `nation` AS `nation` )
WHERE `customer`.`c_custkey` = `orders`.`o_custkey`
AND `customer`.`c_nationkey` = `nation`.`n_nationkey`;

START PIPELINE order_mgt.order_mgmt_lineitem;
START PIPELINE order_mgt.order_mgmt_orders;
START PIPELINE order_mgt.order_mgmt_part;
START PIPELINE order_mgt.order_mgmt_nation;
START PIPELINE order_mgt.order_mgmt_partsupp;
START PIPELINE order_mgt.order_mgmt_region;
START PIPELINE order_mgt.order_mgmt_supplier;
START PIPELINE order_mgt.order_mgmt_customer;

START PIPELINE order_mgt.kafka_lineitem;
START PIPELINE order_mgt.kafka_orders;
START PIPELINE logistics.packages;
START PIPELINE logistics.transitions;
