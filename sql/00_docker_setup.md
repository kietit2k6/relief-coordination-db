# 00 — Môi trường lab: SQL Server 2025 trong Docker

Bộ thực hành chạy trên **một container lab riêng tên `relief-mssql`**. Container này không đụng tới các container khác trên máy (ví dụ `sql-server`, `planwise-postgres`).

## 1. Chuẩn bị

| Thành phần | Giá trị đã dùng khi đo                       |
| ---------- | -------------------------------------------- |
| Image      | `mcr.microsoft.com/mssql/server:2025-latest` |
| Chạy amd64 | `--platform linux/amd64`                     |
| SQL Server | SQL Server version 2025                      |

Kiểm tra trước khi tạo container:

```bash
docker context ls
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker images | grep mssql
lsof -nP -iTCP:1433 -sTCP:LISTEN                   # rỗng = cổng 1433 còn trống
df -h /                                            # cần khoảng 3 GB trống
```

## 2. Đặt mật khẩu SA qua biến môi trường

Mật khẩu **không** được ghi vào script. Mỗi phiên terminal, hãy export biến trước:

```bash
export MSSQL_SA_PASSWORD='<mật-khẩu-mạnh>'   # >= 8 ký tự, có chữ hoa, chữ thường, số và ký hiệu
```

`run_lab.sh` chuyển mật khẩu vào `sqlcmd` qua biến `SQLCMDPASSWORD`, nên mật khẩu không xuất hiện trên dòng lệnh.

## 3. Tạo hoặc khởi động container

```bash
# Tạo mới. Cổng chỉ mở trên localhost của máy.
docker run -d --name relief-mssql --platform linux/amd64 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD \
  -p 127.0.0.1:1433:1433 mcr.microsoft.com/mssql/server:2025-latest

# Lần sau chỉ cần khởi động lại
docker start relief-mssql
```

- **Nếu cổng 1433 đang bận**: đổi vế trái, ví dụ `-p 127.0.0.1:14333:1433`, rồi kết nối tới `localhost,14333`. `run_lab.sh` dùng `docker exec` nên không phụ thuộc cổng ngoài.
- **Nếu `relief-mssql` đã tồn tại**: kiểm tra đúng là container lab bằng `docker inspect relief-mssql --format '{{.Config.Image}} {{json .HostConfig.PortBindings}}'` trước khi dùng lại.

Chờ SQL Server sẵn sàng (lần đầu khoảng 20–40 giây khi chạy qua emulation):

```bash
until docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" relief-mssql \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q "SELECT SERVERPROPERTY('ProductMajorVersion')" >/dev/null 2>&1
do sleep 3; done
```

## 4. Kết nối

**sqlcmd bên trong container**:

```bash
docker exec -it -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" relief-mssql \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -I -d DisasterReliefDB
```

Ý nghĩa các tùy chọn: `-C` tin chứng chỉ tự ký, `-I` bật QUOTED_IDENTIFIER (bắt buộc cho filtered index và indexed view), `-b` trả mã lỗi khi SQL lỗi.

**SSMS** (Windows) hoặc **VS Code + extension MSSQL** (macOS):

- Server: `localhost,1433` (hoặc cổng bạn đã chọn)
- Authentication: SQL Login, user `sa`
- Bật _Trust server certificate_
- Database: `DisasterReliefDB`

Cổng chỉ bind `127.0.0.1`. SSMS chạy trên máy Windows khác sẽ không vào được. Muốn mở ra mạng thì đổi thành `-p 0.0.0.0:1433:1433`, nhưng chỉ nên làm trong mạng tin cậy.

## 5. Thứ tự chạy script

Chạy từ thư mục `sql/`:

```bash
export MSSQL_SA_PASSWORD='...'
# Lượt 1
./run_lab.sh 01_create_schema.sql 02_seed_data.sql 03_baseline_queries.sql \
             04_lab_indexing.sql 05_lab_sargable.sql 06_lab_stats_sniffing.sql \
             07_lab_advanced.sql 08_monitoring.sql
# Reset về trạng thái đầu, chuyển sang lượt 2
./run_lab.sh 09_cleanup_reset.sql
# Lượt 2: chạy lại 04–07 (log có hậu tố _pass2)
LOG_SUFFIX=_pass2 ./run_lab.sh 04_lab_indexing.sql 05_lab_sargable.sql 06_lab_stats_sniffing.sql 07_lab_advanced.sql
# Đối chiếu hai lượt
./run_lab.sh 10_compare_passes.sql
```

Toàn bộ chuỗi trên mất khoảng 2,5 phút trên máy đã đo. Muốn làm lại từ đầu hoàn toàn, xóa database lab trước. Lệnh này chỉ xóa `DisasterReliefDB` trong container lab:

```bash
docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" relief-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -Q \
 "IF DB_ID('DisasterReliefDB') IS NOT NULL BEGIN ALTER DATABASE DisasterReliefDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE DisasterReliefDB; END"
rm -rf evidence/logs evidence/plans
```

| Script                    | Vai trò                                                                                                   |
| ------------------------- | --------------------------------------------------------------------------------------------------------- |
| `01_create_schema.sql`    | Database, 9 bảng / 44 cột, PK/FK/CHECK; compat 170, RECOVERY FULL, Query Store; hạ tầng đo (schema `lab`) |
| `02_seed_data.sql`        | Sinh 261.260 dòng tất định và kiểm tra. Chạy lại chỉ kiểm tra; gặp dữ liệu lệch thì dừng                  |
| `03_baseline_queries.sql` | Thủ tục Mã nguồn 1.3, danh mục truy vấn Q01–Q11, kết quả nghiệp vụ Ca 1 & Ca 2, đo baseline               |
| `04`–`07`                 | Các lab; mỗi phần bắt đầu bằng `lab.usp_ResetLab` và công bố bộ index đầu vào                             |
| `08_monitoring.sql`       | Bộ index đề xuất, đo lại so với baseline, Query Store, index usage, fragmentation                         |
| `09_cleanup_reset.sql`    | Gỡ object/index của lab, khôi phục cấu hình đầu, tăng `PassNo`                                            |
| `10_compare_passes.sql`   | Đối chiếu kết quả, logical reads và plan giữa hai lượt                                                    |
| `run_lab.sh`              | Chỉ điều khiển Docker/sqlcmd, lưu log và tách file `.sqlplan`                                             |

## 6. Cách đo (và cách tái lập một phép đo)

Tất cả phép đo đi qua `lab.usp_Measure` (định nghĩa trong `01_create_schema.sql`):

1. **Cache ấm.** Mỗi biến thể chạy làm nóng 1 lần, sau đó đo 5 lần. Kết quả báo **trung vị** logical reads, CPU (ms) và elapsed (ms).
2. **Nguồn số đo.** Dùng hiệu số `logical_reads`, `cpu_time`, `total_elapsed_time` của `sys.dm_exec_requests` cho chính phiên. Không dùng `SYSDATETIME()`, vì trong container amd64 trên Mac đồng hồ này chỉ nhảy khoảng 5,8 ms một lần.
3. **Biên dịch.** `@FreshCompile = 1` (mặc định) xóa plan cache **của riêng database lab** trước mỗi biến thể, để mỗi tham số được biên dịch cho chính nó. Lab 06 dùng `@FreshCompile = 0` để giữ cached plan khi quan sát parameter sniffing.
4. **Kiểm tra kết quả.** Sau khi đo, harness lưu dấu vân tay (SHA-256) của tập kết quả: một bản theo nội dung (bắt cả số lần xuất hiện của mỗi dòng) và một bản theo thứ tự trả về. `lab.usp_CheckSame` so dấu vân tay giữa hai biến thể.
5. **Actual plan lấy ở lượt riêng.** `run_lab.sh` chạy lại cả script với `lab.RunContext.Mode = 'PLAN'`. Ở lượt này, mỗi biến thể chỉ chạy 1 lần với `SET STATISTICS XML, IO ON`, không ghi số đo. Plan được tách ra `evidence/plans/pass<N>/<CaseID>__<Variant>.sqlplan`; output STATISTICS IO nằm trong `evidence/logs/*_plans.log`.

Tái lập thủ công một ca trong SSMS:

1. Bật _Include Actual Execution Plan_ (Ctrl+M).
2. Chạy `SET STATISTICS IO, TIME ON;` rồi chạy câu lệnh lấy từ `SELECT Stmt, ParamDef FROM lab.Query WHERE QueryID = 'Q01'` với tham số ghi trong RESULTS.md.
3. Chạy một lần để làm nóng, rồi đọc lần chạy thứ hai.

Mở file `.sqlplan` bằng SSMS (File → Open) hoặc extension MSSQL của VS Code để xem plan dạng đồ họa.

**Cache lạnh** không nằm trong kết quả chính. Nếu cần đo, hãy chạy trong một lượt riêng **chỉ trên container lab**: `CHECKPOINT; DBCC DROPCLEANBUFFERS;` trước mỗi lần chạy. `DBCC FREEPROCCACHE` chỉ dùng khi mục đích là đo cả chi phí biên dịch.

## 7. Dọn dẹp

```bash
docker stop relief-mssql     # dừng lab, giữ dữ liệu
docker rm relief-mssql       # xóa hẳn container lab (không ảnh hưởng container khác)
```
