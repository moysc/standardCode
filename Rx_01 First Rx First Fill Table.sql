/*
STARTER CODE MODULE 01 FIRST RX FIRST FILL TABLE

UPDATE HISTORY:
-- 10/31/2018: IMPROVED DOCUMENTATION
			   REMOVED REDUNDANT JOINS
-- 06/26/2018: EDITED THE CODE SO IT DOESN'T BREAK; ADDED FIRST PROVIDER ID/SUPPLIER ID
-- 06/20/2018: ADDED NOT NORMALIZED COST INFO TO EXPANDED FIRST TABLES
-- 04/25/2018: SWITCHED FROM DIM_PRODUCT_NDC11 TO MDMDBA_V_PRODUCT DIMENSION
--			   *NOTE: WITH V_PRODUCT, YOU'LL LIKELY WANT MKTED_PROD_NM FOR PRODUCT GROUPING
--					  AND MKTED_PROD_TYP_CD FOR BRAND/GENERIC FLAGGING (T=BRAND, G=GENERIC, B=BRANDED GENERIC)
--             SWITCHED DIM_PHARMACY_PHARMACYSEQNBR TO MDMDBA_V_PHARMACY
--             SWITCHED PHARMACY_SEQ_NBR TO PHARMACY_ID AND PROVIDER_SEQ_NBR TO PROVIDER_ID
-- 11/02/2017: UPDATED FOR LAAD 2.0
-- CREATED 02/09/2014 BY CHRIS MEISTER
-- SEE UPDATE HISTORY DOCUMENT FOR FURTHER DOCUMENTATION

CODE PURPOSE:
THIS CODE CREATES A TABLE WITH CLAIM DETAILS AND ELIGIBLITY FLAGS FOR NEW-TO-BRAND PATIENT JOURNEY (FIRST RX, APPROVAL, AND FILL) TO BE USED FOR NBRX ANALYSES

TABLES CREATED:
-- NBRX_PREPRO_QC_TRACKER
-- NBRX_PREPRO_1_FIRST_RX
-- NBRX_PREPRO_1_FIRST_RX_EXPANDED
-- NBRX_PREPRO_2_FIRST_APPROVAL
-- NBRX_PREPRO_2_FIRST_APPR_EXPANDED
-- NBRX_PREPRO_3_FIRST_FILL
-- NBRX_PREPRO_3_FIRST_FILL_EXPANDED
-- NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX
-- NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR
-- NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL
-- NBRX_PREPRO_FIRST_RX_FIRST_FILL

PREDECESSOR STEPS (MUST BE RUN BEFORE THIS MODULE):
NONE

STEPS:
	0.CREATE QC TRACKER
	1.CREATE A TABLE WITH DETAILED CLAIM INFO ABOUT EACH FIRST ATTEMPT (PD/RV/RJ)
	2.CREATE A TABLE WITH DETAILED CLAIM INFO ABOUT EACH FIRST APPROVAL (PD/RV)
	3.CREATE A TABLE WITH DETAILED CLAIM INFO ABOUT EACH FIRST FILL (PD ONLY)
	4.CREATE FLAGS TO INDICATE WHETHER A PATIENT'S FIRST RX/APPROVAL/FILL IN THE PRODUCT CLASS
	5.JOIN ALL THE TABLES CREATED ABOVE INTO A SINGLE TABLE
	6.QC
	7.CLEAN-UP

NOTES:
	X FILE ALLOWS FOR MORE THAN ONE CLAIM PER DAY BY INCLUDING "HIDDEN REJECTIONS."
	RX_SEQ IS A FIELD THAT CONCATENATES SVC_DATE, CLAIM_TYP RANKINGS, FILL_TS, AND CLAIM_ID IN ORDER TO ID THE VERY FIRST CLAIM AND CREATE A UNIQUE IDENTIFIER
	'NEW TO CLASS' FLAGS ARE BASED ON THE MARKET BASKET DEFINED BY ALL PRODUCTS INCLUDED IN STEPS 1-3 (ADJUST STEPS 4A-4C TO BROADEN OR NARROW)

PARAMETERS/SEARCH AND REPLACE:
RUN A SEARCH (CTRL + F) AND REPLACE THE FOLLOWING VARIABLES WITHIN THIS CODE TO THE APPROPRIATE VALUES:
	@DATABASE					-- NAME OF PROJECT DB
	@LAAD_PATIENT_ACTIVITY_RX	-- NAME OF PATIENT ACTIVITY TABLE
	@LAAD_RX_FACT				-- NAME OF FACT TABLE
	@PRODUCT_GROUP				-- COMMONLY USED: MKTED_PRODUCT_NM, PRODUCT_GROUP, PRODUCT_OF_INTEREST
	@PRODUCT_LIST				-- FORMAT: 'JANUMET','JANUMET XR','JANUVIA','ONGLYZA','TRADJENTA'

VERSION/EXECUTION HISTORY:
[USE THIS AREA FOR PROJECT-SPECIFIC NOTES ON CODE ITERATIONS]
*/

USE @DATABASE
GO

---------------------------------------------------------------------------------------------
-- STEP 0: CREATE QC TRACKER
---------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_QC_TRACKER' AND TYPE = 'U')

CREATE TABLE NBRX_PREPRO_QC_TRACKER
(
	STEP VARCHAR(4),
	TABLE_NAME VARCHAR(100),
	COMPLETED_TIME DATETIME,
	ROW_COUNT BIGINT
)
GO

PRINT 'PROCESS STARTED AT ' + CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 1: FIND FIRST ATTEMPT CLAIM
---------------------------------------------------------------------------------------------
-- STEP 1A: CREATE TABLE WITH PATIENT ID, PRODUCT, AND FIRST RX SEQUENCE
-- DROP TABLE NBRX_PREPRO_1_FIRST_RX
SELECT
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP,
	MIN(
		CAST(SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
			CASE
				WHEN CLAIM_TYP = 'RJ' THEN '1'
				WHEN CLAIM_TYP = 'RV' THEN '2'
				WHEN CLAIM_TYP = 'PD' THEN '3'
				ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS)
			CASE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
				ELSE '3' END+'-'+ -- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
			CAST(PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
		) AS FIRST_RX_SEQ 
INTO NBRX_PREPRO_1_FIRST_RX
FROM @LAAD_RX_FACT X
	JOIN MDMDBA_V_PRODUCT Y ON X.NDC_CD = Y.NDC
WHERE
	CLAIM_TYP IN ('PD','RV','RJ')
	AND X.ENCOUNTER_FINAL_CLAIM_YN IS NOT NULL -- CHANGE TO 'Y' IF YOU WANT TO EXCLUDE SAME-DAY REJECTIONS
	AND Y.@PRODUCT_GROUP IN (@PRODUCT_LIST)
	-- OPTIONAL: EXCLUDE DISTRIBUTION REJECTIONS FROM FIRST RX ALTOGETHER
	-- AND REJECT_CD NOT IN ('R6','4W')
GROUP BY
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_1_FIRST_RX (PATIENT_ID,@PRODUCT_GROUP,FIRST_RX_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '1A', 'NBRX_PREPRO_1_FIRST_RX', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_1_FIRST_RX
GO

PRINT 'STEP 1 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

-- STEP 1B: EXPAND FIRST RX TABLE TO INCLUDE ALL RELEVANT INFORMATION
-- DROP TABLE NBRX_PREPRO_1_FIRST_RX_EXPANDED
SELECT
	A.PATIENT_ID,
	X.PHARMACY_ID,
	X.PROVIDER_ID,
	A.@PRODUCT_GROUP,
	X.NDC_CD,
	X.SVC_DT AS FIRST_RX_DATE,
	A.FIRST_RX_SEQ,
	X.DATA_GRADE AS FIRST_RX_DATA_GRADE,
	X.CLAIM_TYP AS FIRST_RX_STATUS,
	CASE
		WHEN X.REJECT_CD IN ('69','76','56','N8') AND X.RJCT_RSN_2_CD NOT IN ('69','76','56','N8') AND X.RJCT_RSN_2_CD IS NOT NULL THEN X.RJCT_RSN_2_CD 
		WHEN X.REJECT_CD IN ('69','76','56','N8') AND X.RJCT_RSN_3_CD NOT IN ('69','76','56','N8') AND X.RJCT_RSN_3_CD IS NOT NULL THEN X.RJCT_RSN_3_CD 
		ELSE X.REJECT_CD END AS FIRST_RX_REJ_CODE,
	X.PRIM_PLAN_KEY AS FIRST_RX_PRIM_PLAN_KEY,
	X.DAYS_SUPPLY_CNT AS FIRST_RX_DAYS_SUPPLY_CNT,
	X.DSPNSD_QTY AS FIRST_RX_DSPNSD_QTY,
	X.STD_COPAY AS FIRST_RX_STD_COPAY,
	X.PRIM_PAT_PAY_AMT AS FIRST_RX_PRIM_COPAY,
	X.PRIM_PAT_PAY_AMT_30 AS FIRST_RX_PRIM_COPAY_30,
	X.PRIM_PAT_PAY_AMT_INDEX AS FIRST_RX_PRIM_COPAY_INDEX,
	X.PRIM_PAT_PAY_AMT_30_INDEX AS FIRST_RX_PRIM_COPAY_30_INDEX,
	X.FINAL_OPC AS FIRST_RX_OPC,
	X.FINAL_OPC_30 AS FIRST_RX_OPC_30,
	X.FINAL_OPC_INDEX AS FIRST_RX_OPC_INDEX,
	X.FINAL_OPC_30_INDEX AS FIRST_RX_OPC_30_INDEX,
	X.RXS_30 AS FIRST_RX_RXS_30,
	X.SEC_PLAN_KEY AS FIRST_RX_SEC_PLAN_KEY,
	Z.LIFECYCLE_STATUS AS FIRST_RX_LIFECYCLE_STATUS,
	Z.PLAN_LVL AS FIRST_RX_PLAN_LVL,
	Z.PT_FIN_DATA_LVL AS FIRST_RX_PT_FIN_DATA_LVL,
	Z.COB_YN AS FIRST_RX_COB_YN,
	P.CHNL_CD AS FIRST_RX_CHNL_CD,
	X.PROVIDER_ID AS FIRST_RX_PROVIDER_ID,
	X.SUPPLIER_ID AS FIRST_RX_SUPPLIER_ID
INTO NBRX_PREPRO_1_FIRST_RX_EXPANDED
FROM NBRX_PREPRO_1_FIRST_RX A
	JOIN @LAAD_RX_FACT X
		ON A.PATIENT_ID = X.PATIENT_ID
		AND A.FIRST_RX_SEQ =
			(
			CAST(X.SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
				CASE
					WHEN X.CLAIM_TYP = 'RJ' THEN '1'
					WHEN X.CLAIM_TYP = 'RV' THEN '2'
					WHEN X.CLAIM_TYP = 'PD' THEN '3'
					ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS)
				CASE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
					ELSE '3' END+'-'+ -- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
				CAST(X.PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
			)
	LEFT JOIN DIM_DATA_GRADE Z ON X.DATA_GRADE = Z.DATA_GRADE
	LEFT JOIN MDMDBA_V_PHARMACY P ON X.PHARMACY_ID = P.PHARMACY_ID
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_1_FIRST_RX_EXPANDED (PATIENT_ID,@PRODUCT_GROUP)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '1B', 'NBRX_PREPRO_1_FIRST_RX_EXPANDED', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_1_FIRST_RX_EXPANDED
GO

PRINT 'STEP 1 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 2: FIND FIRST APPROVED CLAIM
---------------------------------------------------------------------------------------------
-- STEP 2A: CREATE TABLE WITH PATIENT ID, PRODUCT, AND FIRST APPROVAL SEQUENCE
-- DROP TABLE NBRX_PREPRO_2_FIRST_APPROVAL
SELECT
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP,
	MIN(
		CAST(SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
			CASE
				WHEN CLAIM_TYP = 'RJ' THEN '1'
				WHEN CLAIM_TYP = 'RV' THEN '2'
				WHEN CLAIM_TYP = 'PD' THEN '3'
				ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS)
			CASE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
				ELSE '3' END+'-'+ -- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
			CAST(PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
	) AS FIRST_APPR_SEQ
INTO NBRX_PREPRO_2_FIRST_APPROVAL
FROM @LAAD_RX_FACT X
	JOIN MDMDBA_V_PRODUCT Y ON X.NDC_CD = Y.NDC
WHERE
	CLAIM_TYP IN ('PD','RV') -- ONLY INCLUDE APPROVED CLAIMS
	AND X.ENCOUNTER_FINAL_CLAIM_YN IS NOT NULL -- CHANGE TO 'Y' IF YOU WANT TO EXCLUDE SAME-DAY REJECTIONS
	AND Y.@PRODUCT_GROUP IN (@PRODUCT_LIST)
GROUP BY
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_2_FIRST_APPROVAL (PATIENT_ID,@PRODUCT_GROUP,FIRST_APPR_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '2A', 'NBRX_PREPRO_2_FIRST_APPROVAL', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_2_FIRST_APPROVAL
GO

PRINT 'STEP 2A COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

-- STEP 2B: EXPAND FIRST APPROVAL TABLE TO INCLUDE ALL RELEVANT INFORMATION
-- DROP TABLE NBRX_PREPRO_2_FIRST_APPR_EXPANDED
SELECT
	A.PATIENT_ID,
	X.PHARMACY_ID,
	X.PROVIDER_ID,
	A.@PRODUCT_GROUP,
	X.NDC_CD,
	X.SVC_DT AS FIRST_APPR_DATE,
	A.FIRST_APPR_SEQ,
	X.DATA_GRADE AS FIRST_APPR_DATA_GRADE,
	X.CLAIM_TYP AS FIRST_APPR_STATUS,
	X.REJECT_CD AS FIRST_APPR_REJ_CODE,
	X.PRIM_PLAN_KEY AS FIRST_APPR_PRIM_PLAN_KEY,
	X.DAYS_SUPPLY_CNT AS FIRST_APPR_DAYS_SUPPLY_CNT,
	X.DSPNSD_QTY AS FIRST_APPR_DSPNSD_QTY,
	X.STD_COPAY AS FIRST_APPR_STD_COPAY,
	X.PRIM_PAT_PAY_AMT AS FIRST_APPR_PRIM_COPAY,
	X.PRIM_PAT_PAY_AMT_30 AS FIRST_APPR_PRIM_COPAY_30,
	X.PRIM_PAT_PAY_AMT_INDEX AS FIRST_APPR_PRIM_COPAY_INDEX,
	X.PRIM_PAT_PAY_AMT_30_INDEX AS FIRST_APPR_PRIM_COPAY_30_INDEX,
	X.FINAL_OPC AS FIRST_APPR_OPC,
	X.FINAL_OPC_30 AS FIRST_APPR_OPC_30,
	X.FINAL_OPC_INDEX AS FIRST_APPR_OPC_INDEX,
	X.FINAL_OPC_30_INDEX AS FIRST_APPR_OPC_30_INDEX,
	X.RXS_30 AS FIRST_APPR_RXS_30,
	X.SEC_PLAN_KEY AS FIRST_APPR_SEC_PLAN_KEY,
	Z.LIFECYCLE_STATUS AS FIRST_APPR_LIFECYCLE_STATUS,
	Z.PLAN_LVL AS FIRST_APPR_PLAN_LVL,
	Z.PT_FIN_DATA_LVL AS FIRST_APPR_PT_FIN_DATA_LVL,
	Z.COB_YN AS FIRST_APPR_COB_YN,
	P.CHNL_CD AS FIRST_APPR_CHNL_CD,
	X.PROVIDER_ID AS FIRST_APPR_PROVIDER_ID,
	X.SUPPLIER_ID AS FIRST_APPR_SUPPLIER_ID
INTO NBRX_PREPRO_2_FIRST_APPR_EXPANDED
FROM NBRX_PREPRO_2_FIRST_APPROVAL A
	JOIN @LAAD_RX_FACT X 
		ON A.PATIENT_ID = X.PATIENT_ID 
		AND A.FIRST_APPR_SEQ = 
			(
			CAST(X.SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
				CASE
					WHEN X.CLAIM_TYP = 'RJ' THEN '1'
					WHEN X.CLAIM_TYP = 'RV' THEN '2'
					WHEN X.CLAIM_TYP = 'PD' THEN '3'
					ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS)
				CASE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
					ELSE '3' END+'-'+ -- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
				CAST(X.PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
			)
	LEFT JOIN DIM_DATA_GRADE Z ON X.DATA_GRADE = Z.DATA_GRADE
	LEFT JOIN MDMDBA_V_PHARMACY P ON X.PHARMACY_ID = P.PHARMACY_ID
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_2_FIRST_APPR_EXPANDED (PATIENT_ID,@PRODUCT_GROUP)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '2B', 'NBRX_PREPRO_2_FIRST_APPR_EXPANDED', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_2_FIRST_APPR_EXPANDED
GO

PRINT 'STEP 2 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 3: FIND FIRST PAID CLAIM
---------------------------------------------------------------------------------------------
-- STEP 3A: CREATE TABLE WITH PATIENT ID, PRODUCT, AND FIRST PAID SEQUENCE
-- DROP TABLE NBRX_PREPRO_3_FIRST_FILL
SELECT
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP,
	MIN(
		CAST(SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
			CASE
				WHEN CLAIM_TYP = 'RJ' THEN '1'
				WHEN CLAIM_TYP = 'RV' THEN '2'
				WHEN CLAIM_TYP = 'PD' THEN '3'
				ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS)
			CASE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
				WHEN ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
				ELSE '3' END+'-'+-- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
			CAST(PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
	) AS FIRST_FILL_SEQ
INTO NBRX_PREPRO_3_FIRST_FILL
FROM @LAAD_RX_FACT X
	JOIN MDMDBA_V_PRODUCT Y ON X.NDC_CD = Y.NDC
WHERE
	CLAIM_TYP = 'PD' -- ONLY INCLUDE FILLED CLAIMS
	AND X.ENCOUNTER_FINAL_CLAIM_YN IS NOT NULL -- CHANGE TO 'Y' IF YOU WANT TO EXCLUDE SAME-DAY REJECTIONS
	AND Y.@PRODUCT_GROUP IN (@PRODUCT_LIST)
GROUP BY
	X.PATIENT_ID,
	Y.@PRODUCT_GROUP
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_3_FIRST_FILL (PATIENT_ID,@PRODUCT_GROUP,FIRST_FILL_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '3A', 'NBRX_PREPRO_3_FIRST_FILL', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_3_FIRST_FILL
GO

PRINT 'STEP 3A COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

-- STEP 3B: EXPAND FIRST FILL TABLE TO INCLUDE ALL RELEVANT INFORMATION
-- DROP TABLE NBRX_PREPRO_3_FIRST_FILL_EXPANDED
SELECT
	A.PATIENT_ID,
	X.PHARMACY_ID,
	X.PROVIDER_ID,
	A.@PRODUCT_GROUP,
	X.NDC_CD,
	X.SVC_DT AS FIRST_FILL_DATE,
	A.FIRST_FILL_SEQ,
	X.DATA_GRADE AS FIRST_FILL_DATA_GRADE,
	X.CLAIM_TYP AS FIRST_FILL_STATUS,
	X.REJECT_CD AS FIRST_FILL_REJ_CODE,
	X.PRIM_PLAN_KEY AS FIRST_FILL_PRIM_PLAN_KEY,
	X.DAYS_SUPPLY_CNT AS FIRST_FILL_DAYS_SUPPLY_CNT,
	X.DSPNSD_QTY AS FIRST_FILL_DSPNSD_QTY,
	X.STD_COPAY AS FIRST_FILL_STD_COPAY,
	X.PRIM_PAT_PAY_AMT AS FIRST_FILL_PRIM_COPAY,
	X.PRIM_PAT_PAY_AMT_30 AS FIRST_FILL_PRIM_COPAY_30,
	X.PRIM_PAT_PAY_AMT_INDEX AS FIRST_FILL_PRIM_COPAY_INDEX,
	X.PRIM_PAT_PAY_AMT_30_INDEX AS FIRST_FILL_PRIM_COPAY_30_INDEX,
	X.FINAL_OPC AS FIRST_FILL_OPC,
	X.FINAL_OPC_30 AS FIRST_FILL_OPC_30,
	X.FINAL_OPC_INDEX AS FIRST_FILL_OPC_INDEX,
	X.FINAL_OPC_30_INDEX AS FIRST_FILL_OPC_30_INDEX,
	X.RXS_30 AS FIRST_FILL_RXS_30,
	X.SEC_PLAN_KEY AS FIRST_FILL_SEC_PLAN_KEY,
	Z.LIFECYCLE_STATUS AS FIRST_FILL_LIFECYCLE_STATUS,
	Z.PLAN_LVL AS FIRST_FILL_PLAN_LVL,
	Z.PT_FIN_DATA_LVL AS FIRST_FILL_PT_FIN_DATA_LVL,
	Z.COB_YN AS FIRST_FILL_COB_YN,
	P.CHNL_CD AS FIRST_FILL_CHNL_CD,
	X.PROVIDER_ID AS FIRST_FILL_PROVIDER_ID,
	X.SUPPLIER_ID AS FIRST_FILL_SUPPLIER_ID
INTO NBRX_PREPRO_3_FIRST_FILL_EXPANDED
FROM NBRX_PREPRO_3_FIRST_FILL A
	JOIN @LAAD_RX_FACT X
		ON A.PATIENT_ID = X.PATIENT_ID
		AND A.FIRST_FILL_SEQ =
			(
			CAST(X.SVC_DT AS VARCHAR)+'-'+ -- MV: SVC_DT INSTEAD OF PATIENT_SEQ BECAUSE PATIENT_SEQ AS A VARCHAR RANKS 9 HIGHER THAN 10 BECAUSE LOOKS AT FIRST DIGIT
				CASE
					WHEN X.CLAIM_TYP = 'RJ' THEN '1'
					WHEN X.CLAIM_TYP = 'RV' THEN '2'
					WHEN X.CLAIM_TYP = 'PD' THEN '3'
					ELSE '4' END+ -- MV: COPY LOGIC FROM FIA TO SEQUENCE IN ORDER OF ADJUDICATION (NOTE THERE ARE A SMALL AMOUNT OF SAME-DAY REVERSALS DRIVEN BY THE ENCOUNTER CLUSTERS) 
				CASE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'Y' THEN '1' -- MV: FINAL CLAIM IS AN RJ BUT THE NON-FINAL IS ALSO RJ, PRIORITIZE THE FINAL ONE
					WHEN X.ENCOUNTER_FINAL_CLAIM_YN = 'N' THEN '2'
					ELSE '3' END+'-'+ -- MV: IF TWO CLAIMS OF THE SAME TYPE (I.E. 2 REJECTIONS) FOR THE SAME ENCOUNTER, TAKE THE "FINAL" ONE
				CAST(X.PRIM_CLAIM_ID AS VARCHAR) -- MV: TIE-BREAKER
			)
	LEFT JOIN DIM_DATA_GRADE Z ON X.DATA_GRADE = Z.DATA_GRADE
	LEFT JOIN MDMDBA_V_PHARMACY P ON X.PHARMACY_ID = P.PHARMACY_ID
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_3_FIRST_FILL_EXPANDED (PATIENT_ID,@PRODUCT_GROUP)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '3B', 'NBRX_PREPRO_3_FIRST_FILL_EXPANDED', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_3_FIRST_FILL_EXPANDED
GO

PRINT 'STEP 3 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEPS 4A, 4B, 4C: FLAG CLAIMS AS NEW TO MARKET ON THE FIRST RX, FIRST APPROVAL, AND FIRST FILL IN THE CLASS
---------------------------------------------------------------------------------------------
-- STEP 4A: FLAG CLAIMS AS NEW TO MARKET ON THE FIRST RX IN THE CLASS
-- DROP TABLE NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX
SELECT
	X.PATIENT_ID,
	X.FIRST_RX_SEQ,
	CASE WHEN Y.NEW_TO_CLASS_RX_SEQ IS NULL THEN 'N' ELSE 'Y' END AS NEW_TO_CLASS_RX_FLAG
INTO NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX
FROM NBRX_PREPRO_1_FIRST_RX X
	LEFT JOIN
	-- EDIT THE NESTED QUERY BELOW TO FIND THE MINIMUM RX_SEQ FOR A NARROWER OR BROADER DRUG CLASS 
		(
		SELECT
			PATIENT_ID, 
			MIN(FIRST_RX_SEQ) AS NEW_TO_CLASS_RX_SEQ
		FROM NBRX_PREPRO_1_FIRST_RX
		GROUP BY PATIENT_ID
		) Y ON Y.PATIENT_ID	= X.PATIENT_ID 
			AND X.FIRST_RX_SEQ = Y.NEW_TO_CLASS_RX_SEQ
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX (PATIENT_ID,FIRST_RX_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '4A', 'NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX
GO

PRINT 'STEP 5A COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

-- STEP 4B: FLAG CLAIMS AS NEW TO MARKET ON THE FIRST APPROVAL IN THE CLASS
-- DROP TABLE NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR
SELECT
	X.PATIENT_ID,
	X.FIRST_APPR_SEQ,
	CASE WHEN Y.NEW_TO_CLASS_APPR_SEQ IS NULL THEN 'N' ELSE 'Y' END AS NEW_TO_CLASS_APPR_FLAG
INTO NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR
FROM NBRX_PREPRO_2_FIRST_APPROVAL X
	LEFT JOIN
	-- EDIT THE NESTED QUERY BELOW TO FIND THE MINIMUM RX_SEQ FOR A NARROWER OR BROADER DRUG CLASS
		(
		SELECT
			PATIENT_ID, 
			MIN(FIRST_APPR_SEQ) AS NEW_TO_CLASS_APPR_SEQ
		FROM NBRX_PREPRO_2_FIRST_APPROVAL
		GROUP BY PATIENT_ID
		) Y ON Y.PATIENT_ID	= X.PATIENT_ID 
			AND X.FIRST_APPR_SEQ = Y.NEW_TO_CLASS_APPR_SEQ
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR (PATIENT_ID,FIRST_APPR_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '4B', 'NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR
GO

PRINT 'STEP 4B COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

-- STEP 4C: FLAG CLAIMS AS NEW TO MARKET ON THE FIRST FILL IN THE CLASS
-- DROP TABLE NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL
SELECT
	X.PATIENT_ID,
	X.FIRST_FILL_SEQ,
	CASE WHEN Y.NEW_TO_CLASS_FILL_SEQ IS NULL THEN 'N' ELSE 'Y' END AS NEW_TO_CLASS_FILL_FLAG
INTO NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL
FROM NBRX_PREPRO_3_FIRST_FILL X
	LEFT JOIN
	-- EDIT THE NESTED QUERY BELOW TO FIND THE MINIMUM RX_SEQ FOR A NARROWER OR BROADER DRUG CLASS
		(SELECT
			PATIENT_ID,
			MIN(FIRST_FILL_SEQ) AS NEW_TO_CLASS_FILL_SEQ
		FROM NBRX_PREPRO_3_FIRST_FILL
		GROUP BY PATIENT_ID
		) Y ON Y.PATIENT_ID = X.PATIENT_ID 
			AND X.FIRST_FILL_SEQ = Y.NEW_TO_CLASS_FILL_SEQ
GO

CREATE CLUSTERED INDEX IX_JOIN ON NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL (PATIENT_ID,FIRST_FILL_SEQ)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '4C', 'NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL
GO

PRINT 'STEP 4 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 5: PUT EVERYTHING TOGETHER IN A TABLE CALLED: NBRX_PREPRO_FIRST_RX_FIRST_FILL
---------------------------------------------------------------------------------------------
-- DROP TABLE NBRX_PREPRO_FIRST_RX_FIRST_FILL
DECLARE @MIN_FACT_DATE DATETIME
DECLARE @MAX_FACT_DATE DATETIME

SET @MIN_FACT_DATE = 
	(SELECT MIN(SVC_DT) FROM @LAAD_RX_FACT)
SET @MAX_FACT_DATE =
	(SELECT MAX(SVC_DT) FROM @LAAD_RX_FACT)

SELECT 
	@MIN_FACT_DATE AS MIN_FACT_DATE,
	@MAX_FACT_DATE AS MAX_FACT_DATE,
	A.*,
	B.FIRST_APPR_DATE,
	B.FIRST_APPR_SEQ,
	B.FIRST_APPR_DATA_GRADE,
	B.FIRST_APPR_STATUS,
	B.FIRST_APPR_PRIM_PLAN_KEY,
	B.FIRST_APPR_DAYS_SUPPLY_CNT,
	B.FIRST_APPR_DSPNSD_QTY,
	B.FIRST_APPR_STD_COPAY,
	B.FIRST_APPR_PRIM_COPAY,
	B.FIRST_APPR_PRIM_COPAY_30,
	B.FIRST_APPR_PRIM_COPAY_INDEX,
	B.FIRST_APPR_PRIM_COPAY_30_INDEX, 
	B.FIRST_APPR_OPC,
	B.FIRST_APPR_OPC_30,
	B.FIRST_APPR_OPC_INDEX,
	B.FIRST_APPR_OPC_30_INDEX, 
	B.FIRST_APPR_RXS_30,
	B.FIRST_APPR_SEC_PLAN_KEY,
	B.FIRST_APPR_LIFECYCLE_STATUS,
	B.FIRST_APPR_PLAN_LVL,
	B.FIRST_APPR_PT_FIN_DATA_LVL,
	B.FIRST_APPR_COB_YN,
	B.FIRST_APPR_CHNL_CD,
	B.FIRST_APPR_PROVIDER_ID,
	B.FIRST_APPR_SUPPLIER_ID,
	DATEDIFF(DAY,A.FIRST_RX_DATE,B.FIRST_APPR_DATE) AS DAYS_RX_TO_APPR,
	C.FIRST_FILL_DATE,
	C.FIRST_FILL_SEQ,
	C.FIRST_FILL_DATA_GRADE,
	C.FIRST_FILL_PRIM_PLAN_KEY,
	C.FIRST_FILL_DAYS_SUPPLY_CNT,
	C.FIRST_FILL_DSPNSD_QTY,
	C.FIRST_FILL_STD_COPAY,
	C.FIRST_FILL_PRIM_COPAY,
	C.FIRST_FILL_PRIM_COPAY_30,
	C.FIRST_FILL_PRIM_COPAY_INDEX,
	C.FIRST_FILL_PRIM_COPAY_30_INDEX, 
	C.FIRST_FILL_OPC,
	C.FIRST_FILL_OPC_30,
	C.FIRST_FILL_OPC_INDEX,
	C.FIRST_FILL_OPC_30_INDEX, 
	C.FIRST_FILL_RXS_30,
	C.FIRST_FILL_SEC_PLAN_KEY,
	C.FIRST_FILL_LIFECYCLE_STATUS,
	C.FIRST_FILL_PLAN_LVL,
	C.FIRST_FILL_PT_FIN_DATA_LVL,
	C.FIRST_FILL_COB_YN,
	C.FIRST_FILL_CHNL_CD,
	C.FIRST_FILL_PROVIDER_ID,
	C.FIRST_FILL_SUPPLIER_ID,
	DATEDIFF(DAY,A.FIRST_RX_DATE,C.FIRST_FILL_DATE)	AS DAYS_RX_TO_FILL,
	DATEDIFF(DAY,B.FIRST_APPR_DATE,C.FIRST_FILL_DATE) AS DAYS_APPR_TO_FILL,
	N1.NEW_TO_CLASS_RX_FLAG,
	N2.NEW_TO_CLASS_APPR_FLAG,
	N3.NEW_TO_CLASS_FILL_FLAG
INTO NBRX_PREPRO_FIRST_RX_FIRST_FILL
FROM NBRX_PREPRO_1_FIRST_RX_EXPANDED A
	LEFT JOIN NBRX_PREPRO_2_FIRST_APPR_EXPANDED B ON A.PATIENT_ID = B.PATIENT_ID
												AND A.@PRODUCT_GROUP = B.@PRODUCT_GROUP
	LEFT JOIN NBRX_PREPRO_3_FIRST_FILL_EXPANDED C ON A.PATIENT_ID = C.PATIENT_ID
												AND A.@PRODUCT_GROUP = C.@PRODUCT_GROUP
	LEFT JOIN NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX N1 ON A.PATIENT_ID = N1.PATIENT_ID
													AND A.FIRST_RX_SEQ = N1.FIRST_RX_SEQ
	LEFT JOIN NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR N2 ON A.PATIENT_ID = N2.PATIENT_ID
													AND B.FIRST_APPR_SEQ = N2.FIRST_APPR_SEQ	
	LEFT JOIN NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL N3 ON A.PATIENT_ID = N3.PATIENT_ID
													AND C.FIRST_FILL_SEQ = N3.FIRST_FILL_SEQ	
ORDER BY A.PATIENT_ID,@PRODUCT_GROUP 
GO

CREATE CLUSTERED INDEX IX_IDBPATIENTID_@PRODUCT_GROUP ON NBRX_PREPRO_FIRST_RX_FIRST_FILL (PATIENT_ID,@PRODUCT_GROUP)
GO

INSERT INTO NBRX_PREPRO_QC_TRACKER
SELECT '5', 'NBRX_PREPRO_FIRST_RX_FIRST_FILL', CURRENT_TIMESTAMP, COUNT(*) FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL
GO

SELECT TOP 1000 * FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL

PRINT 'STEP 5 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 6: QC - CHECK PRODCUTION TRACKER AND OUTPUT TABLE 
---------------------------------------------------------------------------------------------
-- QC A: LOOK THROUGH PRODUCTION TRACKER TO VERIFY THAT NO DUPLICATION OR OTHER ISSUES OCCURRED
SELECT * FROM NBRX_PREPRO_QC_TRACKER ORDER BY STEP
GO

-- PASTE THE RESULTS FROM QC A BELOW FOR THE SAKE OF RECORD-KEEPING
--
--
--
--
--
--
--

-- QC B: OUTPUTS SHOULD BE IDENTICAL
SELECT COUNT(*) FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL
SELECT COUNT(*) FROM (SELECT DISTINCT PATIENT_ID,@PRODUCT_GROUP FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL) A
GO

-- QC C: CHECK THE DISTRIBUTION OF NBRXS BY DATA GRADE
SELECT '1-FIRST RX' AS CATEGORY, YEAR(FIRST_RX_DATE) AS FIRST_RX_YEAR, FIRST_RX_LIFECYCLE_STATUS, COUNT(*) AS COUNT_NBRXS
FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL
GROUP BY YEAR(FIRST_RX_DATE), FIRST_RX_LIFECYCLE_STATUS
UNION
SELECT '2-FIRST APPR' AS CATEGORY, YEAR(FIRST_APPR_DATE) AS FIRST_APPR_YEAR, FIRST_APPR_LIFECYCLE_STATUS, COUNT(*) AS COUNT_NBRXS
FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL
GROUP BY YEAR(FIRST_APPR_DATE), FIRST_APPR_LIFECYCLE_STATUS
UNION
SELECT '3-FIRST FILL' AS CATEGORY, YEAR(FIRST_FILL_DATE) AS FIRST_FILL_YEAR, FIRST_FILL_LIFECYCLE_STATUS, COUNT(*) AS COUNT_NBRXS
FROM NBRX_PREPRO_FIRST_RX_FIRST_FILL
GROUP BY YEAR(FIRST_FILL_DATE), FIRST_FILL_LIFECYCLE_STATUS
ORDER BY 1,2,3

PRINT 'STEP 6 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
GO

---------------------------------------------------------------------------------------------
-- STEP 7: CLEAN-UP
---------------------------------------------------------------------------------------------
/*
--DON'T DROP THE QC TRACKER UNLESS YOU'RE TRYING TO CLEAN UP SANDBOX OR SOMETHING; INSTEAD, KEEEP INSERTING ROWS TO TRACK CHANGES IN THE SAME TABLE OVER TIME
--IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_QC_TRACKER' AND TYPE = 'U')					DROP TABLE NBRX_PREPRO_QC_TRACKER

IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_1_FIRST_RX' AND TYPE = 'U')					DROP TABLE NBRX_PREPRO_1_FIRST_RX
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_1_FIRST_RX_EXPANDED' AND TYPE = 'U')			DROP TABLE NBRX_PREPRO_1_FIRST_RX_EXPANDED
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_2_FIRST_APPROVAL' AND TYPE = 'U')				DROP TABLE NBRX_PREPRO_2_FIRST_APPROVAL
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_2_FIRST_APPR_EXPANDED' AND TYPE = 'U')		DROP TABLE NBRX_PREPRO_2_FIRST_APPR_EXPANDED
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_3_FIRST_FILL' AND TYPE = 'U')					DROP TABLE NBRX_PREPRO_3_FIRST_FILL
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_3_FIRST_FILL_EXPANDED' AND TYPE = 'U')		DROP TABLE NBRX_PREPRO_3_FIRST_FILL_EXPANDED
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX' AND TYPE = 'U')		DROP TABLE NBRX_PREPRO_4A_NEW_TO_CLASS_FIRST_RX
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR' AND TYPE = 'U')	DROP TABLE NBRX_PREPRO_4B_NEW_TO_CLASS_FIRST_APPR
IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL' AND TYPE = 'U')	DROP TABLE NBRX_PREPRO_4C_NEW_TO_CLASS_FIRST_FILL

-- DON'T DROP THE OUTPUT TABLE UNLESS THERE IS AN ISSUE WITH IT
-- IF EXISTS (SELECT NAME FROM SYS.TABLES WHERE NAME = N'NBRX_PREPRO_FIRST_RX_FIRST_FILL' AND TYPE = 'U')		DROP TABLE NBRX_PREPRO_FIRST_RX_FIRST_FILL
GO

PRINT 'STEP 7 COMPLETED ' +  CAST(CURRENT_TIMESTAMP AS VARCHAR(30))
*/