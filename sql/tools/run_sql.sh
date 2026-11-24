#!/usr/bin/env bash
# run_sql.sh — chạy một script .sql bằng sqlcmd BÊN TRONG container SQL Server.
#
# Dùng:   sql/tools/run_sql.sh <file.sql> [log-file] [tham số sqlcmd thêm...]
# Ví dụ:  sql/tools/run_sql.sh 04_verify_schema_data.sql
#
# * Đường dẫn file tính từ thư mục sql/. Toàn bộ sql/ (trừ evidence/) được chép vào
#   /tmp/relief_sql trong container để các lệnh ":r include/..." hoạt động.
# * Mật khẩu KHÔNG ghi ở đâu cả: nếu máy host có biến SQLCMDPASSWORD thì dùng nó,
#   nếu không thì dùng biến MSSQL_SA_PASSWORD sẵn có trong container.
# * Biến môi trường tùy chọn: CONTAINER (mặc định relief-mssql), SQLUSER (mặc định sa).
# * sqlcmd chạy với -b (lỗi -> dừng, mã thoát khác 0), -I (QUOTED_IDENTIFIER ON), -f 65001 (UTF-8).
set -euo pipefail
SQL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="${CONTAINER:-relief-mssql}"
SQLUSER="${SQLUSER:-sa}"
file="${1:?Thiếu tên file .sql}"; shift
log="${1:-}"; [ $# -gt 0 ] && shift

stage_sql() {   # chép sql/ vào container
  docker exec "$CONTAINER" rm -rf /tmp/relief_sql
  docker exec "$CONTAINER" mkdir -p /tmp/relief_sql
  COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$SQL_DIR" --exclude './evidence' -cf - . | docker exec -i "$CONTAINER" tar -C /tmp/relief_sql -xf -
}

run_sqlcmd() {  # $@ = tham số sqlcmd
  if [ -n "${SQLCMDPASSWORD:-}" ]; then
    docker exec -e SQLCMDPASSWORD -w /tmp/relief_sql "$CONTAINER" \
      /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$SQLUSER" -C -b -I -f 65001 "$@"
  else
    docker exec -w /tmp/relief_sql "$CONTAINER" bash -c \
      'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$0" -C -b -I -f 65001 "$@"' \
      "$SQLUSER" "$@"
  fi
}

[ "${SKIP_STAGE:-0}" = 1 ] || stage_sql
if [ -n "$log" ]; then
  mkdir -p "$(dirname "$log")"
  run_sqlcmd -i "$file" "$@" > "$log" 2>&1
else
  run_sqlcmd -i "$file" "$@"
fi
