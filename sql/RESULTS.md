# Kết quả thực hành tối ưu truy vấn — DisasterReliefDB (SQL Server 2025)

Toàn bộ số liệu dưới đây được **đo thật** trên container lab `relief-mssql`, trong lượt chạy sạch ngày 22/11/2026, từ 07:49:05 đến 07:51:22 UTC.

- **Lượt 1**: chạy 01 → 08.
- **Lượt 2**: chạy 09, rồi chạy lại 04 → 07.
- Nếu không ghi chú khác, số liệu là của **lượt 1**. Lượt 2 cho cùng kết quả (xem §9).
- Đường dẫn trong tài liệu tính từ thư mục `sql/`.

Quy ước đọc bảng:

- **reads**: logical reads trung vị của 5 lần đo, sau 1 lần làm nóng (cache ấm).
- **CPU / elapsed**: trung vị, đơn vị ms. Độ phân giải 1 ms, nên giá trị 0–1 ms nghĩa là "dưới 1–2 ms".
- **Bằng chứng**: plan nằm ở `evidence/plans/pass1/<CaseID>__<Variant>.sqlplan` (actual plan, thu ở lượt PLAN riêng). Log đo nằm ở `evidence/logs/<script>.log`, log của lượt plan (kèm STATISTICS IO) ở `evidence/logs/<script>_plans.log`.

---

## 1. Môi trường và cấu hình đo

| Hạng mục | Giá trị |
|---|---|
| Máy chủ vật lý | Apple M2, 16 GiB, macOS 26.5.2 |
| Docker | OrbStack 2.2.4, Docker Engine 29.8.2 (linux/arm64) |
| Container | `relief-mssql`, image `mcr.microsoft.com/mssql/server:2025-latest`, **`--platform linux/amd64`** (Rosetta; `uname -m` = `x86_64`), cổng `127.0.0.1:1433` |
| SQL Server | `Microsoft SQL Server 2025 (RTM-CU9) (KB5122048) - 17.0.5005.3 (X64)`, Enterprise Developer Edition, Ubuntu 24.04.4; `ProductMajorVersion = 17` ✔ |
| Tài nguyên SQL thấy được | 8 CPU logic, 8 scheduler, 6.404 MB RAM; MAXDOP 0; cost threshold for parallelism 5 |
| Database | `DisasterReliefDB`: compat **170**, RECOVERY **FULL**, Query Store **READ_WRITE**, capture mode ALL, interval 5 phút; collation `SQL_Latin1_General_CP1_CI_AS`; RCSI tắt; auto create/update stats bật (đồng bộ) |
| Cấu hình DB-scoped | PSP = ON (mặc định), **CE_FEEDBACK = OFF, CE_FEEDBACK_FOR_EXPRESSIONS = OFF** (lý do ở dưới), DOP_FEEDBACK = ON, OPTIONAL_PARAMETER_OPTIMIZATION = ON, LAST_QUERY_PLAN_STATS = OFF |

**Quyết định kiểm soát nhiễu.** Trong một lượt chạy thử (trước lượt chính thức, không dùng số liệu), tính năng CE Feedback đã tự biên dịch lại thủ tục của Lab 06 sau khoảng 4 lần gọi. Kết quả là một phép đo 5 lần chứa hai plan khác nhau (các lượt 688 → 321 → 293 reads). Query Store ghi nhận nhiều bản `CE Feedback … VERIFICATION_REGRESSED` (xem `evidence/notes/ce_feedback_observed_before_disable.txt`). Để mỗi phép so sánh chỉ thay đổi đúng một yếu tố, database lab tắt `CE_FEEDBACK` và `CE_FEEDBACK_FOR_EXPRESSIONS`. Cấu hình này nằm trong `01_create_schema.sql` và được `lab.usp_ResetLab` khôi phục lại.

**Cách đo** (chi tiết ở `00_docker_setup.md` §6):

- Harness `lab.usp_Measure` lấy hiệu số `logical_reads`, `cpu_time`, `total_elapsed_time` của `sys.dm_exec_requests` cho chính phiên.
- Không dùng `SYSDATETIME()`. Phép đo trực tiếp cho thấy đồng hồ này chỉ có 56 giá trị khác nhau trong 326 ms, tức khoảng 5,8 ms mới nhảy một lần.
- **Kiểm chứng harness:** với truy cập bảng/index thông thường, số reads của harness **trùng khớp** STATISTICS IO:
  - 617 = 617 (scan AuditLog);
  - 1.172 = 525 + 647 (plan song song DOP 8, đã cộng đủ reads của các worker);
  - 23–24 (L1.4).
- **Ngoại lệ:** khi plan có **worktable** hoặc **columnstore (LOB)**, hai bộ đếm lệch nhau. Các ca này báo cả hai con số (§7.3, §7.4).
- Kết quả của mỗi biến thể được xác minh bằng dấu vân tay SHA-256, gồm cả số lần xuất hiện của từng dòng và thứ tự khi thứ tự là nghiệp vụ.
- Tổng cộng **38/38** phép so sánh "phải tương đương" đều đạt ở cả hai lượt. Hai phép so sánh cố ý khác nghĩa (`Expected = DIFFERENT`) đều cho kết quả khác đúng như dự đoán.

---

## 2. Lược đồ và dữ liệu

- **9 bảng / 44 cột / 261.260 dòng**, đúng Hình 1.4 và Bảng 1.2. Inventory giữ nguyên Mã nguồn 1.1: PK ghép (WarehouseID, ItemID), `0 ≤ ReservedQty ≤ Quantity`.
- Có 12 FK và 9 CHECK trên dbo, tất cả đều *trusted*; `DBCC CHECKCONSTRAINTS` sạch.
- Ngoài các ràng buộc của báo cáo, mình bổ sung các CHECK hiển nhiên: `SeverityLevel BETWEEN 1 AND 5`, các số lượng > 0, `Capacity > 0`, `UnitWeight > 0`.
- Bằng chứng: `evidence/logs/02_seed_data.log`. Bản chạy lại chứng minh tính idempotent ("đã đủ — bỏ qua bước sinh"): `evidence/logs/02_seed_data_recheck.log`.

| Bảng | Dòng | Cột | Trang (clustered) |
|---|---:|---:|---:|
| Region | 20 | 4 | 9 |
| Warehouse | 30 | 4 | 9 |
| Category | 10 | 3 | 9 |
| Item | 200 | 5 | 9 |
| Donor | 5.000 | 4 | 73 |
| Inventory | 6.000 | 5 | 41 |
| ReliefRequest | 50.000 | 6 | 313 |
| DispatchOrder | 100.000 | 7 | 529 |
| AuditLog | 100.000 | 6 | 641 |
| **Tổng** | **261.260** | **44** | |

**Sinh dữ liệu.** Dữ liệu được sinh set-based bằng Tally CTE. "Ngẫu nhiên" ở đây là tất định: băm SHA-256 theo (thuộc tính, số dòng), lấy 6 byte làm BIGINT nên luôn ≥ 0. Mọi mốc thời gian nằm trong năm 2025.

**Trạng thái yêu cầu và quy ước xuất kho:**

| Status | Số yêu cầu | Quy ước xuất kho | Vai trò |
|---|---:|---|---|
| Delivered | 34.899 | tổng xuất = lượng yêu cầu | không còn nhu cầu |
| PartiallyDispatched | 5.092 | 0 < tổng xuất < lượng yêu cầu | **còn hiệu lực** |
| Cancelled | 3.892 | không xuất | không tính |
| Approved | 3.567 | chưa xuất | **còn hiệu lực** |
| Pending | 2.550 | chưa xuất | **còn hiệu lực**; Ca 1a |

Kiểm tra trong dữ liệu (đều = 0):

- vật phẩm xuất khác vật phẩm yêu cầu;
- xuất trước thời điểm tạo yêu cầu;
- xuất cho yêu cầu Pending, Approved hoặc Cancelled;
- Delivered nhưng xuất chưa đủ;
- PartiallyDispatched nằm ngoài khoảng (0, yêu cầu);
- xuất vượt lượng yêu cầu.

**Kho theo vùng.** Kho 1–18 thuộc vùng 1–18, kho 19 và 20 thuộc vùng 20, kho 21–30 thuộc vùng 1–10. **Vùng 19 (Điện Biên) không có kho nào**, để Ca 2 có trường hợp vùng có nhu cầu nhưng không có dòng tồn.

**Chọn tham số đo** (từ bảng phân phối K6 trong `02_seed_data.log`):

| Vai trò | Vùng | Tổng yêu cầu | Pending | Pending từ 01/03 đến trước 01/09/2025 |
|---|---|---:|---:|---:|
| Vùng nhiều yêu cầu | **R1 – Quảng Trị** | 12.547 | 657 | **322** |
| Vùng ít yêu cầu | **R16 – Bắc Kạn** | 217 | 13 | **8** |
| Vùng kiểm chứng Ca 2 | R20 – Lai Châu (mức 5) | 220 | **0** | 0 |

Khoảng ngày dùng cho Ca 3 là **[2025-03-01, 2025-09-01)**. Demo phân trang dùng **kho 1, vật phẩm 14**, cặp có nhiều lượt xuất nhất (357 lượt).

---

## 3. Kết quả nghiệp vụ Ca 1 và Ca 2

Câu lệnh nằm trong `lab.Query` (`03_baseline_queries.sql`). Kết quả ở `evidence/logs/03_baseline_queries.log`, các mục B0–B5.

### Ca 1 — Tính nhu cầu còn thiếu

**Ca 1a — "Yêu cầu nào đang chờ xử lý?"** (Q02, `Status = 'Pending'`): có **2.550 yêu cầu** với tổng lượng yêu cầu **638.664**.

**Ca 1b — "Còn bao nhiêu hàng phải cấp?"** (Q03):

- Bước 1: cộng `DispatchedQty` theo `RequestID` trong CTE.
- Bước 2: `LEFT JOIN` vào ReliefRequest có Status ∈ {Pending, Approved, PartiallyDispatched}, nhờ đó giữ được cả những yêu cầu chưa từng được xuất.
- Bước 3: tính phần còn thiếu cho **từng yêu cầu**, rồi mới cộng theo (RegionID, ItemID).

Kết quả: **11.209 yêu cầu còn hiệu lực**, **2.529 cặp (vùng, vật phẩm)**, tổng còn phải cấp **2.144.772**.

- Một phép tính độc lập bằng `OUTER APPLY` tương quan cho đúng **2.144.772**.
- Kiểm tra "xuất vượt lượng yêu cầu" trả về **rỗng**. Script sẽ `THROW 50030` để nhóm đối chiếu nếu có dòng nào.

| Vùng | Yêu cầu còn hiệu lực | Còn phải cấp |
|---|---:|---:|
| R1 Quảng Trị | 2.853 | 533.965 |
| R2 Quảng Bình | 1.654 | 312.079 |
| R3 Hà Tĩnh | 1.101 | 217.035 |
| R4–R15 | 408–490 mỗi vùng | 74.729–93.960 |
| R16–R20 | 34–61 mỗi vùng | 7.144–11.291 |

### Ca 2 — Đối chiếu nhu cầu với tồn kho tại chỗ (Q04)

Cách tính:

- Lượng khả dụng = `Quantity − ReservedQty`; kho thuộc vùng theo `Warehouse.RegionID`.
- Nhu cầu và tồn kho được tổng hợp **độc lập** theo cùng cặp (RegionID, ItemID), rồi mới `LEFT JOIN`.
- Đáp ứng tại chỗ = `min(còn phải cấp, tồn tại chỗ)`.
- Báo cáo **chỉ đọc**, không cập nhật kho.

| Chỉ tiêu | Giá trị |
|---|---:|
| Cặp (vùng, vật phẩm) còn phải cấp | 2.529 |
| Tổng còn phải cấp | 2.144.772 |
| Đáp ứng được bằng hàng tại chỗ | 1.361.838 |
| Còn thiếu sau khi dùng hàng tại chỗ | 782.934 |
| Số cặp vẫn còn thiếu | 590 |
| Vùng 19 (không có kho): 26 vật phẩm, còn phải cấp 8.847, tồn tại chỗ **0**, còn thiếu 8.847 | ✔ được giữ nhờ LEFT JOIN |

Dòng thiếu nhiều nhất là R1, vật phẩm 20 (Sữa và dinh dưỡng trẻ em, Hộp): còn phải cấp 16.316, tồn tại chỗ 1.666, còn thiếu 14.650.

**Tình huống kiểm chứng** nằm ngay trong seed: vùng 20, Nước uống đóng chai, đơn vị Thùng. Yêu cầu 100 thùng, đã xuất 25 + 15, hai kho 19 và 20 còn 25 + 20 = 45 thùng khả dụng. Script `THROW` nếu kết quả sai.

| RegionID | Vật phẩm | Đơn vị | Còn phải cấp | Tồn khả dụng tại chỗ | Đáp ứng được | Còn thiếu tại chỗ |
|---|---|---|---:|---:|---:|---:|
| 20 Lai Châu | 1 Nước uống đóng chai | Thùng | **60** | **45** | **45** | **15** ✔ |

### Hiệu năng của Ca 1 (index DispatchOrder(RequestID) INCLUDE (DispatchedQty))

Lab 04, mục L1.7. Đầu vào: chỉ PK, sau đó thêm đúng index này.

| Mã ca | Truy vấn | Dòng | reads trước → sau | CPU trước → sau | Elapsed trước → sau | Operator thực tế | Plan |
|---|---|---:|---:|---:|---:|---|---|
| CA1-IDX | Q03 (Ca 1b) | 2.529 | **803 → 519** | 38 → 33 | 38 → 33 | DispatchOrder: Clustered Index Scan (510) + Hash Aggregate → **Index Scan `IXDispatchOrderRequest` (226) + Stream Aggregate** (đã có thứ tự theo RequestID) + Merge Join | `CA1-IDX__Q03_before_PK_only_.sqlplan`, `CA1-IDX__Q03_after_IXDispatchOrderRequest.sqlplan` |
| CA1-IDX | Q04 (Ca 2) | 2.529 | **839 → 643** | 46 → 44 | 46 → 44 | Cùng thay đổi ở nhánh DispatchOrder; nhánh tồn kho chuyển sang Nested Loops + Seek Inventory | `CA1-IDX__Q04_*.sqlplan` |

Nhận xét:

- Index **không biến scan thành seek**, vì truy vấn cần mọi lượt xuất để cộng theo yêu cầu.
- Lợi ích có hai phần:
  1. Index hẹp hơn: 224–234 trang so với 508–510 trang của clustered index.
  2. Dữ liệu đã sắp theo `RequestID`, nên Hash Aggregate được thay bằng Stream Aggregate và memory grant giảm từ 8,6 MB xuống 4,3 MB trong actual plan.
- Phần còn lại, 293 reads, là scan ReliefRequest để lọc 3 trạng thái.

---

## 4. Ca 3 — Tối ưu truy vấn Pending theo vùng: ảnh hưởng của index

**Truy vấn Q01**, giữ nguyên trong mọi trạng thái:

```sql
SELECT RequestID, ItemID, RequestedQty, CreatedAt FROM dbo.ReliefRequest
WHERE RegionID = @RegionID AND Status = 'Pending' AND CreatedAt >= @From AND CreatedAt < @To
ORDER BY CreatedAt, RequestID;
```

- Tham số: `@From = '2025-03-01'`, `@To = '2025-09-01'`.
- Mỗi biến thể được biên dịch cho chính tham số của nó (`@FreshCompile = 1`), vì vậy bảng này chỉ phản ánh tác động của **index**.
- Bằng chứng: `evidence/logs/04_lab_indexing.log` và `07_lab_advanced.log` (mục P1).

| Mã ca | Trạng thái (bộ index) | Tham số | Dòng | reads | CPU | Elapsed | Operator / index thực tế | Plan (`evidence/plans/pass1/`) |
|---|---|---|---:|---:|---:|---:|---|---|
| CA3-IDX | **S0** chỉ PK | R1 | 322 | **293** | 4 | 3 | Clustered Index Scan PKReliefRequest (residual cả 3 điều kiện) + **Sort** | `CA3-IDX__S0_baseline_PK_only_R1` |
| CA3-IDX | **S0** chỉ PK | R16 | 8 | **293** | 2 | 3 | như trên | `CA3-IDX__S0_baseline_PK_only_R16` |
| CA3-IDX | **S1** `IXReliefRequestRegionStatus` (báo cáo) | R1 | 322 | **5** | 0 | 1 | **Index Seek** (seek: RegionID, 'Pending', khoảng CreatedAt), **không Sort** | `CA3-IDX__S1_IXReliefRequestRegionStatus_R1` |
| CA3-IDX | **S1** | R16 | 8 | **3** | 0 | 0 | Index Seek, không Sort | `CA3-IDX__S1_IXReliefRequestRegionStatus_R16` |
| CA3-IDX | **S2** filtered `IXReliefRequestPending` (RegionID, CreatedAt) INCLUDE (ItemID, RequestedQty) WHERE Status='Pending' | R1 | 322 | **4** | 0 | 1 | Index Seek trên filtered index | `CA3-IDX__S2_filtered_IXReliefRequestPending_R1` |
| CA3-IDX | **S2** | R16 | 8 | **2** | 0 | 0 | Index Seek trên filtered index | `CA3-IDX__S2_filtered_IXReliefRequestPending_R16` |

Kích thước index:

| Index | Số dòng | Trang dùng |
|---|---:|---:|
| `IXReliefRequestRegionStatus` (báo cáo) | 50.000 | 289 |
| `IXReliefRequestPending` (filtered) | 2.550 | **12** |

**Các biến thể phụ** (mỗi biến thể chỉ thay đúng một yếu tố so với S1):

| Mã ca | Thay đổi | Tham số | Dòng | reads | Operator thực tế | Nhận xét |
|---|---|---|---:|---:|---|---|
| CA3-IDX | L1.4 cùng khóa, **bỏ INCLUDE** | R1 | 322 | 293 | Clustered Index Scan + Sort | Optimizer ước lượng 1.075 Key Lookup là quá đắt nên chọn scan; index không được dùng |
| CA3-IDX | L1.4 | R16 | 8 | 23 (19–23) | Index Seek + **Key Lookup ×8** | Seek cộng lookup vẫn tốt hơn scan khi ít dòng |
| CA3-IDX | L1.5 **đảo thứ tự khóa** (CreatedAt, RegionID, Status) | R1 | 322 | 140 | Seek chỉ theo CreatedAt, **residual** RegionID/Status | Cột phạm vi đứng đầu nên phải đọc mọi vùng trong 6 tháng |
| CA3-IDX | L1.5 | R16 | 8 | 140 | như trên | Vùng ít dòng nhưng chi phí không giảm |
| CA3-IDX | S2, nhưng `Status = @Status` là **tham số** | R1 | 322 | 293 | Clustered Index Scan | Filtered index **không dùng được** khi điều kiện lọc là tham số |
| CA3-IDX | S3 có **cả** index báo cáo lẫn filtered | R1 | 322 | 5 | Index Seek trên **IXReliefRequestRegionStatus** | Optimizer chọn index báo cáo. Ở Lab 08, filtered index có 0 lượt đọc (§8) |

- Kết quả tương đương: mọi trạng thái đều trả **cùng 322 dòng (R1) và 8 dòng (R16), cùng thứ tự**, so với S0.
- **Missing-index DMV** sau baseline gợi ý equality `[RegionID], [Status]`, inequality `[CreatedAt]`, include `[ItemID], [RequestedQty]` (avg_user_impact 90,28%). Đây đúng là index của báo cáo.

**Kết luận Ca 3 (phần index):**

- Index của báo cáo giảm logical reads **98–99%**: 293 → 5 cho R1 và 293 → 3 cho R16, đồng thời bỏ được bước Sort.
- Filtered index tiết kiệm thêm 1 read và nhỏ hơn khoảng 24 lần, nhưng chỉ có tác dụng khi `'Pending'` là hằng trong câu lệnh.
- Khi đã có index báo cáo, filtered index trở nên thừa.

---

## 5. Ca 3 — Parameter sniffing và PSP (bộ index cố định)

**Bộ index cố định** cho cả thí nghiệm: `IXReliefRequestRegionStatusNarrow` (RegionID, Status, CreatedAt), **không INCLUDE**.

- Mình chọn index này vì §4 cho thấy nó dẫn tới hai plan khác nhau theo tham số: R16 dùng seek + lookup, R1 dùng scan.
- Với index covering của báo cáo, mọi vùng đều dùng chung một plan Seek tốt, nên không có hiện tượng sniffing để quan sát.

Thiết lập thí nghiệm:

- Truy vấn Q01 được đóng gói trong `exp.uspPendingByRegion`.
- Giữ cached plan giữa các lần gọi (`@FreshCompile = 0`). Việc biên dịch lại chỉ xảy ra qua `sp_recompile` trên đúng thủ tục.
- Bằng chứng: `evidence/logs/06_lab_stats_sniffing.log`; plan `SNIFF-*`, `STATS-EST__*`.

**Statistics.** Histogram của RegionID có 20 bước và EQ_ROWS khớp tuyệt đối với số đếm: R1 = 12.547, R16 = 217. Density vector:

| Tổ hợp cột | Density |
|---|---|
| RegionID | 0,05 |
| (RegionID, Status) | 0,0101 |
| (RegionID, Status, CreatedAt) | 2,0×10⁻⁵ |

Optimizer ước lượng **1.075,2 dòng cho R1** (thực tế 322) và **41,3 dòng cho R16** (thực tế 8). Như vậy ước lượng cao gấp 3–5 lần, vì histogram chỉ có trên cột đầu, còn các điều kiện Status và CreatedAt được ước lượng theo giả định độc lập.

| Mã ca | Cấu hình | Biên dịch với | Chạy với | Operator theo dõi | Est. rows | Actual rows | Dòng | reads | CPU | Elapsed |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|
| STATS-EST | tự biên dịch | R1 | R1 | Clustered Index Scan | 1.075,2 | 322 | 322 | 293 | 4 | 4 |
| STATS-EST | tự biên dịch | R16 | R16 | Index Seek (Narrow) | 41,3 | 8 | 8 | 23 | 0 | 0 |
| SNIFF-OFF | PSP **tắt**, C1 | **16** | 16 | Index Seek + 8 Key Lookup | 41,3 | 8 | 8 | 23 | 1 | 0 |
| SNIFF-OFF | PSP tắt, C1 | **16** | **1** | Index Seek + **322 Key Lookup** (615 reads trong plan) | 41,3 | **322** | 322 | **688** | 1 | 1 |
| SNIFF-OFF | PSP tắt, C2 (sau `sp_recompile`) | **1** | 1 | Clustered Index Scan + Sort | 1.075,2 | 322 | 322 | 293 | 3 | 4 |
| SNIFF-OFF | PSP tắt, C2 | **1** | **16** | Clustered Index Scan + Sort | 1.075,2 | **8** | 8 | **293** | 2 | 3 |
| SNIFF-FIX | D1 `OPTION (RECOMPILE)` | giá trị thật | R1 | Clustered Index Scan | 1.075,2 | 322 | 322 | 319 | 6 | 6 |
| SNIFF-FIX | D1 `OPTION (RECOMPILE)` | giá trị thật | R16 | Index Seek + Lookup | 41,3 | 8 | 8 | 55 | 2 | 2 |
| SNIFF-FIX | D2 `OPTIMIZE FOR (@RegionID = 1)` | 1 | R1 | Clustered Index Scan | 1.075,2 | 322 | 322 | 293 | 3 | 4 |
| SNIFF-FIX | D2 | 1 | R16 | Clustered Index Scan | 1.075,2 | 8 | 8 | 293 | 2 | 2 |
| SNIFF-FIX | D3 `OPTIMIZE FOR UNKNOWN` | (mật độ) | R1 | Clustered Index Scan | 359,5 | 322 | 322 | 293 | 4 | 4 |
| SNIFF-FIX | D3 | (mật độ) | R16 | Clustered Index Scan | 359,5 | 8 | 8 | 293 | 2 | 3 |
| SNIFF-PSP | PSP **bật**, compat 170, E1 | 16 | 16 | Index Seek + Lookup | 41,3 | 8 | 8 | 23 | 0 | 0 |
| SNIFF-PSP | PSP bật, E1 | 16 | **1** | Index Seek + **322 Key Lookup** | 41,3 | 322 | 322 | **688** | 1 | 1 |
| SNIFF-PSP | PSP bật, E2 | 1 | 1 | Clustered Index Scan | 1.075,2 | 322 | 322 | 293 | 4 | 3 |
| SNIFF-PSP | PSP bật, E2 | 1 | **16** | Clustered Index Scan | 1.075,2 | 8 | 8 | **293** | 3 | 2 |

Giá trị "biên dịch với / chạy với" đọc từ `ParameterCompiledValue` / `ParameterRuntimeValue` trong actual plan. Est/actual rows đọc tại cùng operator.

**Nhận xét:**

- **Sniffing được tái hiện ở cả hai chiều:**
  - Plan biên dịch cho vùng ít dòng, đem chạy vùng nhiều dòng: **688 reads**, gấp 2,3 lần plan riêng (293), vì phải làm 322 Key Lookup.
  - Plan biên dịch cho vùng nhiều dòng, đem chạy vùng ít dòng: **293 reads**, gấp 12,7 lần plan riêng (23).
  - Kết quả nghiệp vụ không đổi: dấu vân tay giống nhau giữa C1 và C2.
- **Thời gian chạy không phản ánh rõ:** 1–4 ms trên cache ấm và 322 lookup trong bộ nhớ nằm sát độ phân giải đồng hồ. Logical reads mới là chỉ số phân biệt.
- **`OPTION (RECOMPILE)` luôn chọn đúng plan, nhưng trả giá biên dịch** ở mỗi lần gọi: thêm 26–32 reads (đọc metadata/statistics) và 2–4 ms CPU. Cụ thể 319 so với 293 cho R1, 55 so với 23 cho R16.
- **`OPTIMIZE FOR`** cố định plan scan cho mọi vùng: tốt cho R1 nhưng gấp 12,7 lần cho R16.
- **`OPTIMIZE FOR UNKNOWN`** ước lượng theo mật độ (359,5 dòng) và cũng chọn scan.

**PSP ở compat 170 KHÔNG kích hoạt.** Bằng chứng:

1. **Extended Events** `parameter_sensitive_plan_optimization_skipped_reason`, thu từ các batch "sạch" (mỗi batch chỉ gọi một thủ tục):

   | Thủ tục | Lý do bỏ qua |
   |---|---|
   | `exp.uspPendingByRegion` (Ca 3, có hằng `Status = 'Pending'`) | **UnsupportedPredicateType** |
   | `exp.uspPspProbe_RegionOnly` (chỉ `RegionID = @RegionID`) | **SkewnessThresholdNotMet** |
   | `exp.uspPspProbe_StatusParam` (`RegionID = @RegionID AND Status = @Status`) | **SkewnessThresholdNotMet** |

2. `sys.query_store_query_variant` **rỗng**. Query Store chỉ có `plan_type = 0 (Compiled Plan)`, không có Dispatcher Plan.
3. Actual plan không có thuộc tính `Dispatcher` / `QueryVariantID`.
4. Số đo của E1/E2 trùng hoàn toàn với C1/C2.

Kết luận: với dữ liệu này, chênh lệch R1/R16 khoảng 58 lần trên 50.000 dòng là **chưa đủ ngưỡng lệch** để PSP hoạt động. Thêm vào đó, câu lệnh của Ca 3 có vị từ hằng nên bị loại ngay từ bước kiểm tra kiểu vị từ. Muốn tránh sniffing ở Ca 3, cách thực tế là dùng **index covering của báo cáo** (§4): mọi vùng dùng chung một plan seek 3–5 reads.

---

## 6. Demo dự phòng — Phân trang lịch sử xuất kho (OFFSET vs keyset)

- Đầu vào: PK + `IXDispatchOrderWarehouseItem` (báo cáo).
- Kho 1, vật phẩm 14, có 357 lượt xuất.
- Thứ tự duy nhất: `DispatchedAt DESC, DispatchID DESC`.
- Keyset dùng **khóa cuối của trang trước** làm mốc.
- Bằng chứng: `07_lab_advanced.log` (mục P2), plan `PAGE-*`.

| Mã ca | Trang | Mốc (khóa cuối trang trước) | Cách | Dòng | reads | Operator thực tế | Cùng 50 DispatchID, cùng thứ tự? |
|---|---|---|---|---:|---:|---|---|
| PAGE-DISPATCH | 2 (bỏ qua 50) | 2025-11-21 20:05:00 / 21178 | OFFSET | 50 | **3** | Index Seek đọc 100 dòng → Top | ✔ |
| PAGE-DISPATCH | 2 | 2025-11-21 20:05:00 / 21178 | keyset | 50 | **6** | Index Seek (2 khoảng seek do `OR`) → Top 50 | ✔ |
| PAGE-DISPATCH | 7 (bỏ qua 300) | 2025-03-01 08:18:00 / 46064 | OFFSET | 50 | **5** | Index Seek đọc 350 dòng → Top | ✔ |
| PAGE-DISPATCH | 7 | 2025-03-01 08:18:00 / 46064 | keyset | 50 | **6** | Index Seek → Top 50 | ✔ |
| PAGE-AUDIT | 60 (bỏ qua 2.950; AuditLog kho 5, index (WarehouseID, LoggedAt)) | 2025-02-15 10:27:00 / 5408 | OFFSET | 50 | **21** | Index Seek đọc **3.000** dòng → Top | ✔ |
| PAGE-AUDIT | 60 | 2025-02-15 10:27:00 / 5408 | keyset | 50 | **6** | Index Seek đọc **50** dòng | ✔ |

**Nhận xét:**

- Với 357 dòng mỗi cặp (kho, vật phẩm), toàn bộ dữ liệu nằm trong vài trang lá, nên **OFFSET còn rẻ hơn** (3–5 so với 6 reads).
- Keyset tốn cố định 6 reads, vì điều kiện `DispatchedAt < @LastAt OR (DispatchedAt = @LastAt AND DispatchID < @LastID)` tạo hai khoảng seek, mỗi khoảng đi lại từ gốc B-tree.
- Ưu điểm của keyset chỉ lộ ra khi trang sâu: ở trang 60 của AuditLog, OFFSET phải đọc 3.000 dòng (21 reads), keyset chỉ đọc 50 dòng (6 reads). Chi phí của OFFSET tăng theo số dòng bỏ qua, còn keyset gần như không đổi.

---

## 7. Các lab còn lại

### 7.1 Lab 04 — index của báo cáo cho lịch sử xuất (Q06)

| Mã ca | Tham số | Dòng | reads trước → sau | CPU | Operator | Plan |
|---|---|---:|---:|---:|---|---|
| Q06-IDX | kho 1, vật phẩm 14, quý 2/2025 | 99 | **510 → 5** | 5 → 1 | Clustered Index Scan + Sort → **Index Seek `IXDispatchOrderWarehouseItem`** (seek trên cả 3 cột khóa, covering, không Sort) | `Q06-IDX__*.sqlplan` |

### 7.2 Lab 05 — SARGable

- Index covering ở từng phần để chỉ cách viết điều kiện là khác nhau.
- Bằng chứng: `05_lab_sargable.log`, plan `S1-*` … `S5-*`.

| Mã ca | Cách viết | Tham số | Dòng | reads | CPU | Seek / residual / cảnh báo trong plan |
|---|---|---|---:|---:|---:|---|
| S1-DATE | `YEAR()/MONTH()/DAY()` trên cột | 15/06/2025 | 300 | **583** | 17 | Index **Scan**; residual `datepart(...)` |
| S1-DATE | `CONVERT(CHAR(8), LoggedAt, 112)` | 15/06/2025 | 300 | **583** | 19 | Index Scan; cảnh báo **PlanAffectingConvert** (Cardinality Estimate, Seek Plan) |
| S1-DATE | `CAST(LoggedAt AS DATE) = @Day` | 15/06/2025 | 300 | **7** | 0 | **Vẫn Seek**: SQL Server tự sinh khoảng động (Constant Scan + Seek [Expr1004, Expr1005]), kèm residual `CONVERT(date, …)` |
| S1-DATE | khoảng nửa mở `>= @Day AND < @Day + 1` | 15/06/2025 | 300 | **5** | 0 | Seek, không residual |
| S2-PHONE | `@Phone VARCHAR(20)` | SĐT của donor 1234 | 1 | **2** | 0 | Index Seek `IXDonorPhone` |
| S2-PHONE | `@Phone NVARCHAR(20)` | như trên | 1 | **52** | 1 | Clustered Index **Scan**; `CONVERT_IMPLICIT(nvarchar(20), Phone)`; cảnh báo PlanAffectingConvert (Seek Plan) |
| S2-STATUS | `@Status VARCHAR(20)` (Q01, R1) | R1 | 322 | **5** | 1 | Seek trên (RegionID, Status, CreatedAt) |
| S2-STATUS | `@Status NVARCHAR(20)` | R1 | 322 | **72** | 2 | Chỉ seek được theo RegionID; Status và CreatedAt thành **residual**; thêm Sort |
| S3-LIKE | `LIKE '%' + '01234'` | | 1 | 34 | 8 | Seek dạng khoảng toàn chỉ mục (Constant Scan + Seek), residual `like` trên mọi dòng |
| S3-LIKE | `LIKE 'Nguyễn Văn An' + '%'` | | 9 | 2 | 0 | Seek khoảng hẹp. **Câu hỏi khác nghĩa** (hậu tố vs tiền tố), không có phép viết lại tương đương cho `'%x'` trên lược đồ hiện tại |
| S4-OR | `RequestID = @R OR DonorID = @D` | R=12346, D=1526 (có 1 dòng thỏa cả hai) | 24 | **4** | 0 | Optimizer **tự** dùng index union: 2 Index Seek + Merge Join (concatenation) + Stream Aggregate loại trùng |
| S4-OR | `UNION ALL` + điều kiện bù `RequestID <> @R` | như trên | 24 | **4** | 0 | 2 Index Seek + Merge Join, bỏ được bước loại trùng. **Không nhanh hơn**, cùng 4 reads |
| S5-ISNULL | `ISNULL(DonorID,0) = ISNULL(@D,0)` | D=777 | 1 | **276** | 6 | Index **Scan**, residual `isnull(...)` |
| S5-ISNULL | `DonorID = @D OR (DonorID IS NULL AND @D IS NULL)` | D=777 | 1 | **2** | 0 | Index Seek |
| S5-ISNULL | `ISNULL(...)` | D=NULL (10.094 lượt xuất không có donor) | 1 | **276** | 7 | Index Scan |
| S5-ISNULL | `OR IS NULL` | D=NULL | 1 | **30** | 3 | Index Seek vào đoạn NULL |

Tất cả các cặp đều trả cùng kết quả, kể cả trường hợp `@DonorID = NULL` và dòng thỏa cả hai vế của OR. `ISNULL(DonorID, 0)` tương đương với cách viết `OR IS NULL` vì DonorID là FK tới Donor(1..5000), không có giá trị 0.

### 7.3 Lab 07 — EXISTS/IN/JOIN, window function, columnstore, indexed view, cursor

Bằng chứng: `07_lab_advanced.log` (P3–P7), plan tương ứng trong `evidence/plans/pass1/`.

**EXISTS / IN / JOIN.** Câu hỏi: "Nhà tài trợ nào đã tài trợ hàng xuất từ kho 7?". Index `(WarehouseID, DonorID)`.

| Cách viết | Dòng | reads | Plan | Kết luận |
|---|---:|---:|---|---|
| EXISTS | 1.422 | 60 | Merge Join (semi) | — |
| IN | 1.422 | 60 | **giống hệt** EXISTS | optimizer chuẩn hóa về cùng semi join |
| JOIN + DISTINCT | 1.422 | 60 | giống hệt | |
| JOIN không DISTINCT | **1.685** | 60 | | **sai nghĩa**: nhân bản nhà tài trợ có nhiều lượt xuất (đã kiểm `DIFFERENT`) |
| NOT EXISTS | 3.578 | 60 | Merge Join (anti) | đúng |
| NOT IN (subquery có DonorID NULL) | **0** | 57 | thêm Row Count Spool kiểm tra NULL | **sai nghĩa**: chỉ cần một NULL là trả rỗng |
| NOT IN + `IS NOT NULL` | 3.578 | 59 | | đúng, tương đương NOT EXISTS |

**Window function so với subquery tương quan.** Câu hỏi: "lượt xuất gần nhất của mỗi yêu cầu thuộc vùng 4", có giữ trường hợp trùng thời điểm. Index (RequestID, DispatchedAt) INCLUDE (…). Cả ba cách đều trả 1.610 dòng, cùng thứ tự.

| Cách viết | reads (harness) | STATISTICS IO | CPU | Operator thực tế |
|---|---:|---|---:|---|
| a. subquery tương quan `MAX` | **397** | DispatchOrder 381 + ReliefRequest 16 | 25 | Index Scan + Segment + **Top** (lấy dòng MAX mỗi nhóm) + Hash Join |
| b. `MAX() OVER (PARTITION BY)` | **16.464** | DispatchOrder 381 + ReliefRequest 16 + **Worktable 14.453** | 24 | Merge Join → Segment → **Table Spool** (8.013 reads trong plan) → Nested Loops |
| c. `GROUP BY MAX` rồi JOIN | 778 | 2 × Index Scan 381 + 16 | 44 | Stream Aggregate + 2 Hash Join |

Nhận xét: trong trường hợp này **window function tệ nhất về reads**, gấp khoảng 41 lần so với subquery tương quan. Window aggregate không có ORDER BY, chạy ở row mode, được hiện thực bằng Table Spool đọc lại từng nhóm. CPU của ba cách tương đương nhau (24–44 ms). Trong bảng này, harness (16.464) và STATISTICS IO (14.850) lệch nhau ở phần worktable, nên cả hai số đều được ghi.

**Nonclustered columnstore** cho báo cáo tổng hợp theo tháng:

| Mã ca | Truy vấn | Dòng | Trước (chỉ PK) | Sau (+ NCCI) |
|---|---|---:|---|---|
| NCCI | DispatchOrder: lượt xuất & tổng lượng theo kho × tháng | 387 | reads 525 (harness = STATISTICS IO), **DOP 8 row mode**, CPU 176 ms, elapsed **29 ms** | harness 162; STATISTICS IO: logical 0, **lob logical 332**, segment reads 1; **batch mode, DOP 1**, CPU **46 ms**, elapsed **46 ms** |
| NCCI | AuditLog: số bản ghi & tổng Delta theo ActionType × tháng | 48 | reads 647 (lần đo dao động 647–1.473 do scan song song), DOP 8, CPU 226 ms, elapsed **44 ms** | harness 166; lob logical 338, segment reads 1; batch mode, DOP 1, CPU **97 ms**, elapsed **97 ms** |

Mỗi columnstore gồm 1 rowgroup COMPRESSED 100.000 dòng, khoảng 1,2 MB (156–163 trang), so với 510–617 trang của clustered rowstore.

Nhận xét:

- Columnstore **giảm số trang đọc** (525 → 332 trang LOB) và **giảm CPU 2,3–3,8 lần**.
- Nhưng **elapsed tăng**: plan columnstore có chi phí ước lượng thấp nên chạy serial, trong khi plan rowstore chạy song song 8 luồng.
- Đây là đánh đổi thật trên máy đo: NCCI có lợi về tổng tài nguyên khi nhiều người cùng chạy báo cáo, chứ không có lợi về độ trễ của một lần chạy đơn lẻ ở quy mô 100.000 dòng.

**Indexed view** `exp.vInventoryByRegionItem`: tồn khả dụng theo (RegionID, ItemID), unique clustered index.

| Truy vấn (giữ nguyên chữ, không NOEXPAND) | Dòng | reads trước → sau | CPU | Plan sau |
|---|---:|---:|---:|---|
| Tồn khả dụng theo vùng × vật phẩm | 3.800 | **29 → 18** | 7 → 2 | Clustered Index Scan trên **view** (view matching tự động) |
| Q04 (Ca 2, có phần tồn kho như trên) | 2.529 | **643 → 643** | 43 → 42 | **Không dùng view**: plan trước và sau giống hệt nhau |

Nhận xét: view matching hoạt động với truy vấn đơn, nhưng **không xảy ra** khi biểu thức tồn kho nằm trong CTE của truy vấn Ca 2 nhiều nhánh. Indexed view còn làm mọi UPDATE trên Inventory phải bảo trì thêm view, tăng tranh chấp khóa trên đúng bảng trọng tâm của chương 3. Với 6.000 dòng Inventory, lợi ích (11 reads) không đáng để đánh đổi.

**Cursor (Mã nguồn 1.3) so với set-based.** `@MinSeverity = 4`, gồm 9 vùng.

| Biến thể | Dòng ra | reads | CPU | Elapsed | Ghi chú plan |
|---|---:|---:|---:|---:|---|
| a. Thủ tục gốc: cursor FAST_FORWARD + PRINT | 691 dòng PRINT | **2.858** | 13 | 13 | 694 plan câu lệnh trong một lần gọi (mỗi FETCH là một câu lệnh); Worktable 1.412 reads + 692 lần FETCH × 2 reads |
| b. Set-based (một SELECT, giữ cộng theo vùng × vật phẩm, giữ dòng "chưa có yêu cầu chờ") | 691 | **48** | 4 | 4 | 1 câu SELECT tổng hợp |
| c. Cùng vòng cursor nhưng gom kết quả vào biến bảng (chỉ để kiểm tra nghĩa) | 691 | 3.650 | 20 | 20 | |

- b và c **trùng tập kết quả**, cùng 691 dòng.
- Đã kiểm thêm: tổng Pending theo từng vùng khớp với phép tính trực tiếp.
- Vùng 20 (Lai Châu, mức 5) có đúng một dòng: `Lai Châu [Bao dong do]: chưa có yêu cầu chờ.`
- Cursor tốn reads gấp khoảng **60 lần** set-based.

---

## 8. Giám sát (08_monitoring.sql)

Bộ index đề xuất sau các lab:

- `IXReliefRequestRegionStatus`
- `IXDispatchOrderWarehouseItem`
- `IXDispatchOrderRequest`
- `IXAuditLogWarehouseTime`
- thêm `IXReliefRequestPending` (filtered) để kiểm tra xem nó có được dùng hay không.

Bằng chứng: `evidence/logs/08_monitoring.log`.

**Baseline (chỉ PK) so với bộ index đề xuất.** Cùng truy vấn, cùng tham số; dấu vân tay kết quả trùng ở mọi dòng.

| Truy vấn | Tham số | Dòng | reads baseline → đề xuất | Giảm | CPU | Elapsed |
|---|---|---:|---:|---:|---:|---:|
| Q01 Ca 3 | R1 | 322 | 293 → 5 | 98,3% | 4 → 1 | 4 → 0 |
| Q01 Ca 3 | R16 | 8 | 293 → 3 | 99,0% | 2 → 0 | 3 → 0 |
| Q02 Ca 1a | — | 2.550 | 300 → 87 | 71,0% | 10 → 6 | 10 → 6 |
| Q03 Ca 1b | — | 2.529 | 803 → 519 | 35,4% | 37 → 33 | 38 → 33 |
| Q04 Ca 2 | — | 2.529 | 839 → 631 | 24,8% | 49 → 46 | 49 → 47 |
| Q05 tồn kho khả dụng | R20, vật phẩm 1 | 2 | 6 → 6 | 0% | 0 → 1 | 0 → 0 |
| Q06 lịch sử xuất | kho 1, vật phẩm 14, Q2 | 99 | 510 → 5 | 99,0% | 5 → 0 | 5 → 0 |
| Q07 top nhà tài trợ | Q2/2025 | 10 | 540 → 540 | 0% | 13 → 14 | 13 → 14 |
| Q08 phân trang AuditLog | kho 5, bỏ qua 100 | 50 | 617 → 4 | 99,4% | 7 → 0 | 7 → 0 |

Q05 đã dùng seek trên PK của Inventory từ trước. Q07 lọc theo `DispatchedAt` trên toàn bộ bảng, không có index phù hợp trong bộ đề xuất, nên vẫn scan (§10).

**Query Store.**

- Khoảng đo tính từ số đo đầu tiên của lượt, 07:49:28 UTC. Database được tạo mới lúc 07:49, nên Query Store chỉ chứa lượt này.
- Thống kê được gom theo interval của Query Store, từ 07:00 đến 07:55 UTC (interval đầu dài 60 phút, trước khi cấu hình 5 phút có hiệu lực), tổng 20.625 lượt thực thi.
- Đã loại câu lệnh của harness. Phần còn lại bao gồm cả phép kiểm tra nghiệp vụ và CREATE INDEX của lab, vì đó là tải thật.
- "Tổng reads" = trung bình × số lần chạy.

| Hạng (theo tổng reads) | Câu lệnh | Lượt chạy | Tổng logical reads | Reads trung bình/lần |
|---|---|---:|---:|---:|
| 1 | Phép đối chiếu độc lập của Ca 1b trong 03 (`OUTER APPLY` tương quan trên DispatchOrder khi chưa có index RequestID) | 2 | 452.540 | **226.270** |
| 2 | Window `MAX() OVER` (Lab 07, P4) | 8 | 134.990 | 16.873,8 |
| 3 | Q04 Ca 2 (mọi lab) | 49 | 80.495 | 1.642,8 |
| 4 | Q03 Ca 1b | 33 | 53.097 | 1.609,0 |
| 5 | CREATE INDEX IXReliefRequestRegionStatus (các lab) | 13 | 35.067 | 2.697,5 |

Phát hiện: **câu tốn tài nguyên nhất không phải truy vấn nghiệp vụ, mà là câu kiểm tra dữ liệu** viết bằng subquery tương quan khi chưa có index. Riêng nó tiêu tốn 226 nghìn reads mỗi lần chạy. Bảng tổng (trung bình × số lần) và bảng trung bình mỗi lần cho thứ hạng khác nhau: CREATE COLUMNSTORE INDEX đứng thứ 3 theo trung bình nhưng chỉ chạy 2 lần.

**Index usage, index không thấy lượt đọc, fragmentation.** Dữ liệu tính từ lúc tạo bộ index đề xuất trong 08; SQL Server khởi động lúc 05:42:42.

| Index | Seeks | Scans | Lookups | Updates | Trang | Phân mảnh |
|---|---:|---:|---:|---:|---:|---:|
| IXReliefRequestRegionStatus | 21 | 7 | 0 | 0 | 274 | 2,55% |
| IXDispatchOrderWarehouseItem | 7 | 0 | 0 | 0 | 425 | 1,65% |
| IXDispatchOrderRequest | 0 | 14 | 0 | 0 | 224 | 6,70% |
| IXAuditLogWarehouseTime | 7 | 0 | 0 | 0 | 579 | 1,21% |
| **IXReliefRequestPending** (filtered) | **0** | **0** | **0** | 0 | 10 | 0% |

- **Index chưa quan sát thấy lượt đọc trong phiên lab:** chỉ có `IXReliefRequestPending`. Kết quả này khớp với S3 ở §4: khi đã có index báo cáo, optimizer luôn chọn index báo cáo.
- Mọi index đều dưới 1.000 trang và phân mảnh dưới 7%, nên **không cần REBUILD/REORGANIZE**.
- PKItem có 66,67% phân mảnh nhưng chỉ 3 trang, không có ý nghĩa thực tế.

---

## 9. Tái lập: lượt 2 sau 09_cleanup_reset

Quy trình:

- `09_cleanup_reset.sql` gỡ mọi index/object của lab và khôi phục cấu hình: compat 170, PSP ON, CE feedback OFF, không XE session.
- Kiểm tra sau reset: 0 index phụ, 0 object trong `exp`, 9 PK, 12 FK, 9 CHECK, 261.260 dòng (`09_cleanup_reset.log`, `09_cleanup_reset_final.log`).
- Sau đó chạy lại 04–07 (`*_pass2.log`, `evidence/plans/pass2/`) và `10_compare_passes.sql` (`evidence/logs/10_compare_passes.log`).

| Tiêu chí | Kết quả |
|---|---|
| Biến thể so sánh (04–07) | 77 |
| Cùng số dòng trả về | **77/77** |
| Cùng dấu vân tay kết quả (tập dòng + thứ tự) | **76/76** biến thể có result set. Biến thể còn lại là thủ tục cursor chỉ PRINT |
| Cùng logical reads trung vị | **77/77** |
| Cùng hình dạng plan (query_plan_hash từ Query Store) | 76/77 (giải thích bên dưới) |
| Cùng chuỗi operator + index trong actual plan (96 file `.sqlplan` chung của hai lượt) | **96/96** |
| Phép so sánh "phải tương đương" trong mỗi lượt | 38/38 ở cả hai lượt |

Biến thể lệch duy nhất: ở lượt 2, `SNIFF-PSP | E2 … R1` ghi nhận **thêm** hash `0xD1F40544BB94EACB`. Đó là plan seek của biến thể E1 chạy ngay trước, lọt vào cửa sổ thu theo `last_execution_time` của Query Store. File actual plan của hai lượt giống hệt nhau (Sort + Clustered Index Scan), và số đo cũng giống. Đây là giới hạn của cách thu bằng Query Store, không phải plan thay đổi.

CPU và elapsed giữa hai lượt lệch nhau 0–4 ms ở các ca nặng nhất, ví dụ Q04: 46 so với 50 ms CPU.

**Kiểm tra độc lập bộ file bàn giao.** Sau lượt chính thức, mình có sửa vài chi tiết không ảnh hưởng tới số đo: phép đếm FK/CHECK giới hạn trong schema dbo ở 02/09, một câu PRINT ở 06, và mẫu grep trong `run_lab.sh`. Sau đó mình chạy lại **toàn bộ chuỗi 01 → 10 từ database trống** bằng đúng các file trong `sql/`, trên một bản sao riêng để không ghi đè bằng chứng.

- Logical reads trung vị và số dòng của **95/95** biến thể lượt 1 **trùng khớp** với số liệu trong tài liệu này.
- Phép đối chiếu hai lượt cho đúng kết quả như trên (77/77, 76/76, 76/77 với cùng hash thừa ở E2).

---

## 10. Giới hạn và các mục chưa đo

- **Cache lạnh: chưa đo.** Mọi số liệu đều đo trên cache ấm, theo đúng yêu cầu dùng cache ấm làm kết quả chính. Cách đo cache lạnh trên container lab được ghi ở `00_docker_setup.md` §6.
- **Thời gian chỉ có ý nghĩa so sánh trong môi trường này.** SQL Server x64 chạy qua Rosetta trên Mac, độ phân giải 1 ms. Các truy vấn dưới 5 ms không nên dùng để kết luận về tốc độ; nên dùng logical reads.
- **Harness và STATISTICS IO** khớp tuyệt đối khi truy cập bảng/index, nhưng **khác nhau khi có worktable** (window: 16.464 so với 14.850) và **khi có columnstore** (162/166 so với lob logical 332/338). Các ca này đã báo cả hai con số.
- **Bộ đếm reads theo từng operator trong showplan** (`ActualLogicalReads`) có thể nhỏ hơn STATISTICS IO, ví dụ 14 so với 24 ở L1.4 R16. Bảng kết quả dùng harness / STATISTICS IO.
- **PSP**: không kích hoạt được với dữ liệu này (§5). Mình không tăng độ lệch của dữ liệu để "ép" PSP chạy, vì như vậy sẽ thay đổi bộ seed 261.260 dòng.
- **CE feedback đã tắt** để số đo lặp lại được. Trong vận hành thật với cấu hình mặc định, plan có thể tự thay đổi sau vài lần chạy.
- **Q07 (top nhà tài trợ theo khoảng ngày)** chưa được tối ưu. Index trên `DispatchedAt` hoặc NCCI (§7.3) là hướng tiếp theo nhưng chưa đo.
- **Query Store**: thống kê bị làm tròn theo interval; số lượt thực thi bao gồm cả lượt PLAN (mỗi biến thể thêm 1 lần chạy).
