/* =====================================================================
   09_cleanup_reset.sql — gỡ object/index do lab tạo, khôi phục cấu hình lab
   về trạng thái đầu đã công bố, rồi chuyển sang lượt đo mới (PassNo + 1).
   GIỮ NGUYÊN: 9 bảng, dữ liệu seed 261.260 dòng, PK/FK/CHECK, thủ tục của
   báo cáo dbo.uspReportUrgentRegions, hạ tầng đo trong schema lab và các số
   đo/plan của lượt trước (để so sánh ở 10_compare_passes.sql), Query Store.
   Trạng thái đầu đã công bố (lab.usp_ResetLab):
     * chỉ clustered PK trên 9 bảng; không index phụ, không object trong schema exp
     * statistics do lab/auto tạo bị xóa; UPDATE STATISTICS ... WITH FULLSCAN
     * compat 170, PSP = ON, CE_FEEDBACK = OFF, CE_FEEDBACK_FOR_EXPRESSIONS = OFF,
       LAST_QUERY_PLAN_STATS = OFF; không có XE session lab_psp; plan cache của DB đã xóa
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
DECLARE @next INT = ISNULL((SELECT MAX(PassNo) FROM lab.Measurement), 0) + 1;
UPDATE lab.RunContext SET PassNo = @next, Mode = 'MEASURE';
SELECT PassNo AS NextPassNo, Mode FROM lab.RunContext;
GO
PRINT N'== Kiểm tra sau reset ==';
SELECT N'Index phụ trên dbo (phải = 0)' AS CheckItem, COUNT(*) AS Value
FROM sys.indexes i WHERE OBJECT_SCHEMA_NAME(i.object_id) = N'dbo' AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.index_id > 1 AND i.is_primary_key = 0
UNION ALL SELECT N'Object trong schema exp (phải = 0)', COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = N'exp'
UNION ALL SELECT N'Clustered PK trên dbo (phải = 9)', COUNT(*) FROM sys.indexes i
          WHERE OBJECT_SCHEMA_NAME(i.object_id) = N'dbo' AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.is_primary_key = 1
UNION ALL SELECT N'FK trên dbo (phải = 12)', COUNT(*) FROM sys.foreign_keys WHERE SCHEMA_NAME(schema_id) = N'dbo'
UNION ALL SELECT N'CHECK trên dbo (phải = 9)', COUNT(*) FROM sys.check_constraints WHERE SCHEMA_NAME(schema_id) = N'dbo'
UNION ALL SELECT N'Tổng số dòng 9 bảng (phải = 261260)',
          (SELECT COUNT_BIG(*) FROM dbo.Region) + (SELECT COUNT_BIG(*) FROM dbo.Warehouse) + (SELECT COUNT_BIG(*) FROM dbo.Category)
        + (SELECT COUNT_BIG(*) FROM dbo.Item) + (SELECT COUNT_BIG(*) FROM dbo.Donor) + (SELECT COUNT_BIG(*) FROM dbo.Inventory)
        + (SELECT COUNT_BIG(*) FROM dbo.ReliefRequest) + (SELECT COUNT_BIG(*) FROM dbo.DispatchOrder) + (SELECT COUNT_BIG(*) FROM dbo.AuditLog)
UNION ALL SELECT N'Compatibility level (phải = 170)', compatibility_level FROM sys.databases WHERE name = DB_NAME()
UNION ALL SELECT N'XE session lab_psp (phải = 0)', COUNT(*) FROM sys.server_event_sessions WHERE name = N'lab_psp';
SELECT name, value FROM sys.database_scoped_configurations
WHERE name IN (N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', N'CE_FEEDBACK', N'CE_FEEDBACK_FOR_EXPRESSIONS', N'LAST_QUERY_PLAN_STATS');
IF EXISTS (SELECT 1 FROM sys.indexes i WHERE OBJECT_SCHEMA_NAME(i.object_id) = N'dbo' AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
           AND i.index_id > 1 AND i.is_primary_key = 0)
   OR EXISTS (SELECT 1 FROM sys.objects WHERE SCHEMA_NAME(schema_id) = N'exp')
    THROW 50060, N'Reset chưa sạch.', 1;
GO
