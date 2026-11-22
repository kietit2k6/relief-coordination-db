/* =====================================================================
   10_compare_passes.sql — đối chiếu lượt 1 (01–08) với lượt 2 (sau 09, chạy
   lại 04–07): kết quả nghiệp vụ (dấu vân tay), logical reads trung vị và
   hình dạng plan (query_plan_hash từ Query Store ở lượt PLAN).
   Chạy sau khi đã có ít nhất 2 lượt. Mặc định so lượt lớn nhất với lượt trước nó.
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
DECLARE @p2 INT = (SELECT MAX(PassNo) FROM lab.Measurement);
DECLARE @p1 INT = @p2 - 1;
IF @p1 < 1 THROW 50070, N'Cần ít nhất 2 lượt đo.', 1;
SELECT @p1 AS PassA, @p2 AS PassB;

IF OBJECT_ID('tempdb..#cmp') IS NOT NULL DROP TABLE #cmp;
SELECT a.CaseID, a.Variant,
       a.RowsReturned AS RowsA, b.RowsReturned AS RowsB,
       a.MedianReads AS ReadsA, b.MedianReads AS ReadsB,
       a.MedianCpuMs AS CpuA, b.MedianCpuMs AS CpuB,
       a.MedianElapsedMs AS ElapsedA, b.MedianElapsedMs AS ElapsedB,
       CASE WHEN fa.BagHash IS NULL AND fb.BagHash IS NULL THEN NULL
            WHEN fa.BagHash = fb.BagHash AND fa.OrderHash = fb.OrderHash THEN 1 ELSE 0 END AS SameResult,
       CASE WHEN sa.PlanHashes IS NULL OR sb.PlanHashes IS NULL THEN NULL
            WHEN sa.PlanHashes = sb.PlanHashes THEN 1 ELSE 0 END AS SamePlanShape,
       sa.PlanHashes AS PlanHashesA, sb.PlanHashes AS PlanHashesB
INTO #cmp
FROM lab.vMeasureSummary a
JOIN lab.vMeasureSummary b ON b.CaseID = a.CaseID AND b.Variant = a.Variant AND b.PassNo = @p2
OUTER APPLY (SELECT TOP (1) BagHash, OrderHash FROM lab.Fingerprint x WHERE x.PassNo = @p1 AND x.CaseID = a.CaseID AND x.Variant = a.Variant ORDER BY x.FingerprintID DESC) fa
OUTER APPLY (SELECT TOP (1) BagHash, OrderHash FROM lab.Fingerprint x WHERE x.PassNo = @p2 AND x.CaseID = a.CaseID AND x.Variant = a.Variant ORDER BY x.FingerprintID DESC) fb
OUTER APPLY (SELECT TOP (1) PlanHashes FROM lab.PlanShape x WHERE x.PassNo = @p1 AND x.CaseID = a.CaseID AND x.Variant = a.Variant ORDER BY x.PlanShapeID DESC) sa
OUTER APPLY (SELECT TOP (1) PlanHashes FROM lab.PlanShape x WHERE x.PassNo = @p2 AND x.CaseID = a.CaseID AND x.Variant = a.Variant ORDER BY x.PlanShapeID DESC) sb
WHERE a.PassNo = @p1;

PRINT N'== C1. Tổng hợp đối chiếu hai lượt ==';
SELECT COUNT(*) AS VariantsCompared,
       SUM(CASE WHEN RowsA = RowsB THEN 1 ELSE 0 END) AS SameRowCount,
       SUM(CASE WHEN SameResult = 1 THEN 1 ELSE 0 END) AS SameResultHash,
       SUM(CASE WHEN SameResult IS NULL THEN 1 ELSE 0 END) AS NoResultSet,
       SUM(CASE WHEN ReadsA = ReadsB THEN 1 ELSE 0 END) AS SameMedianReads,
       SUM(CASE WHEN SamePlanShape = 1 THEN 1 ELSE 0 END) AS SamePlanShape,
       SUM(CASE WHEN SamePlanShape IS NULL THEN 1 ELSE 0 END) AS PlanShapeNotCaptured
FROM #cmp;
PRINT N'== C2. Các biến thể có khác biệt (kết quả, reads hoặc plan) ==';
SELECT CaseID, Variant, RowsA, RowsB, ReadsA, ReadsB, SameResult, SamePlanShape, PlanHashesA, PlanHashesB
FROM #cmp
WHERE RowsA <> RowsB OR SameResult = 0 OR ReadsA <> ReadsB OR SamePlanShape = 0
ORDER BY CaseID, Variant;
PRINT N'== C3. Toàn bộ bảng đối chiếu ==';
SELECT CaseID, Variant, RowsA, RowsB, ReadsA, ReadsB, CpuA, CpuB, ElapsedA, ElapsedB, SameResult, SamePlanShape
FROM #cmp ORDER BY CaseID, Variant;
PRINT N'== C4. So sánh tương đương trong từng lượt (lab.Equivalence) ==';
SELECT PassNo, Expected, COUNT(*) AS Checks,
       SUM(CASE WHEN BagEqual = 1 AND ISNULL(OrderEqual, 1) = 1 THEN 1 ELSE 0 END) AS Equal,
       SUM(CASE WHEN BagEqual = 0 OR OrderEqual = 0 THEN 1 ELSE 0 END) AS NotEqual
FROM lab.Equivalence WHERE PassNo IN (@p1, @p2) GROUP BY PassNo, Expected ORDER BY PassNo, Expected;
GO
