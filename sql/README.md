# DisasterReliefDB — triển khai database (SQL Server 2025)

Database gồm 9 bảng / 44 cột với 261.260 dòng dữ liệu mẫu, theo Hình 1.4 và Bảng 1.2 của báo cáo.

## Yêu cầu

- Docker đang chạy container SQL Server 2025, mặc định tên `relief-mssql`. Nếu container có tên khác, đặt `export CONTAINER=<tên>`.
- Đã có database `DisasterReliefDB`. Nếu chưa có, tạo trước:

```bash
docker exec relief-mssql bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q "CREATE DATABASE DisasterReliefDB"'
```

Mật khẩu lấy từ biến `MSSQL_SA_PASSWORD` có sẵn trong container, không ghi vào file nào.

## Triển khai (chạy từ thư mục gốc repo)

```bash
sql/tools/run_sql.sh 01_schema.sql              # tạo 9 bảng, khóa, ràng buộc
sql/tools/run_sql.sh 03_seed_data.sql           # sinh 261.260 dòng (~20 giây)
sql/tools/run_sql.sh 04_verify_schema_data.sql  # kiểm tra: phải 34/34 PASS
sql/tools/run_sql.sh 02_indexes.sql             # 2 index theo Mã nguồn 1.1
```

Các script chạy lại được an toàn: phần nào đã có thì bỏ qua, và script sẽ dừng nếu database ở trạng thái lạ. Nếu dùng SSMS, mở từng file theo thứ tự trên và bật **Query → SQLCMD Mode** trước khi chạy.

## Kiểm tra nhanh

```sql
USE DisasterReliefDB;
SELECT t.name, SUM(p.rows) AS SoDong
FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY t.name ORDER BY t.name;
```

Số dòng mong đợi:

| Bảng | Số dòng |
|---|---:|
| Region | 20 |
| Warehouse | 30 |
| Category | 10 |
| Item | 200 |
| Donor | 5.000 |
| Inventory | 6.000 |
| ReliefRequest | 50.000 |
| DispatchOrder | 100.000 |
| AuditLog | 100.000 |
