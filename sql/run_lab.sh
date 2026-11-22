#!/usr/bin/env bash
# run_lab.sh — chạy các script .sql trong container relief-mssql.
#  * Lượt MEASURE: chạy script, log có header cột -> evidence/logs/<script><suffix>.log
#  * Nếu script có gọi lab.usp_Measure: chạy LẠI cả script ở Mode = 'PLAN'
#    (mỗi biến thể chạy 1 lần với STATISTICS XML/IO, không ghi số đo)
#    -> evidence/logs/<script><suffix>_plans.log, rồi tách từng actual plan
#    thành evidence/plans/pass<N>/<CaseID>__<Variant>.sqlplan
#
# Dùng:  export MSSQL_SA_PASSWORD='...'
#        ./run_lab.sh 01_create_schema.sql 02_seed_data.sql ...
# Biến tùy chọn: CONTAINER (mặc định relief-mssql), LOG_SUFFIX (vd _pass2), PLANS=0 để bỏ lượt plan
set -euo pipefail
cd "$(dirname "$0")"
: "${MSSQL_SA_PASSWORD:?Hãy export MSSQL_SA_PASSWORD trước khi chạy}"
CONTAINER="${CONTAINER:-relief-mssql}"
LOG_SUFFIX="${LOG_SUFFIX:-}"
PLANS="${PLANS:-1}"
mkdir -p evidence/logs evidence/plans
SQLCMD=(docker exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CONTAINER"
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -f 65001)
# -b: lỗi SQL => mã lỗi khác 0 | -I: QUOTED_IDENTIFIER ON (filtered index, indexed view)

set_mode() { "${SQLCMD[@]}" -d DisasterReliefDB -Q "SET NOCOUNT ON; UPDATE lab.RunContext SET Mode = '$1';" >/dev/null; }

run_one() {  # $1 = file, $2 = log, rest = sqlcmd display options
  local f="$1" log="$2"; shift 2
  local start=$(date +%s)
  if "${SQLCMD[@]}" "$@" < "$f" > "$log" 2>&1; then
    echo "    OK   $(( $(date +%s) - start ))s  -> $log"
  else
    echo "    FAILED ($(( $(date +%s) - start ))s) -> $log"; tail -n 30 "$log"; return 1
  fi
}

for f in "$@"; do
  base="$(basename "$f" .sql)"
  echo ">>> $f"
  # Lượt đo: header cột, cột ngăn bằng '|', bỏ khoảng trắng thừa
  run_one "$f" "evidence/logs/${base}${LOG_SUFFIX}.log" -W -s '|' || exit 1

  if [ "$PLANS" = 1 ] && grep -qE "^EXEC lab\.usp_Measure" "$f"; then
    plog="evidence/logs/${base}${LOG_SUFFIX}_plans.log"
    set_mode PLAN
    # -y 0: không cắt cột XML (showplan dài hơn 8000 ký tự)
    if ! run_one "$f" "$plog" -y 0; then set_mode MEASURE; exit 1; fi
    set_mode MEASURE
    perl -0777 -ne '
      while (/##PLAN-BEGIN## ([^\r\n]+)(.*?)##PLAN-END##/sg) {
        my ($tag, $body) = ($1, $2);
        my @f = split /\|/, $tag; my $case = shift @f; my $pass = pop @f; my $variant = join("|", @f);
        (my $name = "${case}__${variant}") =~ s/[^A-Za-z0-9_.-]+/_/g;
        my $dir = "evidence/plans/$pass"; mkdir $dir unless -d $dir;
        my $k = 0;
        while ($body =~ /(<ShowPlanXML.*?<\/ShowPlanXML>)/sg) {
          $k++;
          next if $k > 10;   # thủ tục cursor sinh 1 plan cho mỗi FETCH: chỉ giữ 10 plan đầu
          my $file = $k == 1 ? "$dir/$name.sqlplan" : "$dir/${name}_stmt$k.sqlplan";
          open my $fh, ">", $file or die $!; print $fh $1; close $fh;
        }
        open my $mf, ">>", "$dir/_manifest.txt" or die $!;
        printf $mf "%s\t%d statement plan(s)%s\n", $name, $k, ($k > 10 ? ", saved first 10" : "");
        close $mf;
      }' "$plog"
    echo "    plans -> evidence/plans/ ($(grep -c '##PLAN-BEGIN##' "$plog") biến thể)"
  fi
done
