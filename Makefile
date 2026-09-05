now = $(shell date "+%Y%m%d%H%M%S")
app = isuumo
service = isuumo.go.service
godir = go
mysql_auth = 

# 構成: i1 = web(nginx + アプリ) / i2 = chair の MySQL / i3 = estate の MySQL
# chair と estate は JOIN もまたぐトランザクションも無いのでテーブル単位で分けている。
web_host = i1
chair_db_host = i2
estate_db_host = i3

# ベンチ(練習: i1 で実行 / 本戦: ポータルから)
.PHONY: bench
bench:
	ssh i1 'cd isuumo/bench && ./bench -target-url http://127.0.0.1'

# ベンチ前の一括準備。ローカルから叩いて web と DB を役割ごとに再起動する。
.PHONY: prepare
prepare:
	ssh isucon@${web_host} -A 'cd isuumo/webapp && make re'
	ssh isucon@${chair_db_host} -A 'cd isuumo/webapp && make dbre'
	ssh isucon@${estate_db_host} -A 'cd isuumo/webapp && make dbre'
	echo "正常に make prepare が完了しました"

# web ホスト(${web_host})で実行する。アプリと nginx の再起動。
.PHONY: re
re:
	make arestart
	make nrestart
	echo "正常に make re が完了しました"

# DB ホスト(${chair_db_host} / ${estate_db_host})で実行する。MySQL の再起動とスロークエリログの初期化。
.PHONY: dbre
dbre:
	make mrestart
	echo "正常に make dbre が完了しました"

.PHONY: arestart
arestart:
	sudo systemctl daemon-reload
	sudo systemctl restart ${service}
	sudo systemctl status ${service} --no-pager

.PHONY: nrestart
nrestart:
	# ここは計測用のリセット経路(report.sh reset が叩く)。logoff のまま計測すると
	# alp が空になって気づけないので、必ずアクセスログを ON に戻してから回す。
	make nlogon
	sudo touch /var/log/nginx/access.log
	sudo rm /var/log/nginx/access.log
	sudo systemctl reload nginx
	sudo systemctl status nginx --no-pager

.PHONY: mrestart
mrestart:
	sudo touch /var/log/mysql/slow.log
	sudo rm /var/log/mysql/slow.log
	sudo mysqladmin flush-logs ${mysql_auth}
	sudo systemctl restart mysql
	# 再起動直後は接続を受け付けないことがある。下の set global が落ちると make が
	# そこで中断し、prepare の残り(別の DB ホスト)が実行されないまま起動途中の
	# MySQL にベンチが走って初期化に失敗する。応答するまで待つ。
	for i in $$(seq 1 30); do sudo mysqladmin ping ${mysql_auth} >/dev/null 2>&1 && break; sleep 1; done
	sudo systemctl status mysql --no-pager
	echo "set global slow_query_log = 1;" | sudo mysql ${mysql_auth}
	echo "set global slow_query_log_file = '/var/log/mysql/slow.log';" | sudo mysql ${mysql_auth}
	echo "set global long_query_time = 0;" | sudo mysql ${mysql_auth}

# ---------------------------------------------------------------------------
# ログの ON / OFF
#
#   make logon   計測用。nginx のアクセスログ(alp)と MySQL のスロークエリログ(pt)を出す
#   make logoff  本番走行用。全部止めて再起動する。スコアを狙う走行の直前に叩く
#
# アプリのエラーログは logoff でも残る(正常系では1行も出ないのでコストは無く、
# 500 が出たときにこれが無いと切り分けられない)。
#
# 注意: make prepare / report.sh は計測用なので、nrestart と mrestart が
# nginx と MySQL のログを ON に戻す。logoff の状態で走らせたいなら
# prepare を挟まずに logoff → ベンチの順で叩くこと。
# ---------------------------------------------------------------------------
.PHONY: logon logoff
logon:
	ssh isucon@${web_host} -A 'cd isuumo/webapp && make nlogon alogon'
	ssh isucon@${chair_db_host} -A 'cd isuumo/webapp && make mlogon'
	ssh isucon@${estate_db_host} -A 'cd isuumo/webapp && make mlogon'
	echo "ログを ON にしました(計測用)"

logoff:
	ssh isucon@${web_host} -A 'cd isuumo/webapp && make nlogoff alogoff'
	ssh isucon@${chair_db_host} -A 'cd isuumo/webapp && make mlogoff'
	ssh isucon@${estate_db_host} -A 'cd isuumo/webapp && make mlogoff'
	echo "ログを OFF にしました(本番走行用)"

# web ホストで実行。nginx のアクセスログ。
# nginx.conf は http レベルで access_log off、server ブロックが
# /etc/nginx/access-log.d/*.conf を include する。on.conf を置くと server レベルで
# 上書きされて記録が始まる。access-log.d は Git 管理外(実行時に追跡ファイルを
# 書き換えるとサーバー側の git pull が壊れるため)。
.PHONY: nlogon nlogoff
nlogon:
	sudo mkdir -p /etc/nginx/access-log.d
	echo 'access_log /var/log/nginx/access.log ltsv;' | sudo tee /etc/nginx/access-log.d/on.conf > /dev/null
	sudo nginx -t
	sudo systemctl reload nginx

nlogoff:
	sudo rm -f /etc/nginx/access-log.d/on.conf
	sudo nginx -t
	sudo systemctl reload nginx

# web ホストで実行。アプリのアクセスログ(1リクエスト1行の JSON)。
# env.sh は isuumo.go.service の EnvironmentFile で Git 管理外なので直接書く。
.PHONY: alogon alogoff
alogon:
	sed -i '/^ISU_ACCESS_LOG=/d' /home/isucon/env.sh
	echo 'ISU_ACCESS_LOG=1' >> /home/isucon/env.sh
	make arestart

alogoff:
	sed -i '/^ISU_ACCESS_LOG=/d' /home/isucon/env.sh
	make arestart

# DB ホストで実行。スロークエリログ。
.PHONY: mlogon mlogoff
mlogon:
	echo "set global slow_query_log = 1;" | sudo mysql ${mysql_auth}
	echo "set global long_query_time = 0;" | sudo mysql ${mysql_auth}

mlogoff:
	echo "set global slow_query_log = 0;" | sudo mysql ${mysql_auth}

# nginx のアクセスログを alp で集計
.PHONY: nalp
nalp:
	sudo cat /var/log/nginx/access.log | alp ltsv --sort=sum --reverse -m "^/api/chair/[0-9]+$$,^/api/chair/buy/[0-9]+$$,^/api/estate/[0-9]+$$,^/api/estate/req_doc/[0-9]+$$,^/api/recommended_estate/[0-9]+$$"

.PHONY: pt
pt:
	sudo pt-query-digest /var/log/mysql/slow.log > ~/pt.log

.PHONY: ptselect
ptselect:
	sudo pt-query-digest --filter '$$event->{arg} =~ m/^SELECT/' /var/log/mysql/slow.log > ~/pt.log

.PHONY: pprof
pprof:
	curl -o /home/isucon/cpu-profile.prof http://localhost:6060/debug/pprof/profile?seconds=45
	go tool pprof /home/isucon/cpu-profile.prof

.PHONY: build
build: $(wildcard ${godir}/*.go) ${godir}/go.mod ${godir}/go.sum
	cd ${godir} && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ${app}

define upload
	ssh isucon@$(1) 'sudo systemctl daemon-reload'
	ssh isucon@$(1) 'sudo systemctl stop ${service}'
	scp ./${godir}/${app} isucon@$(1):/home/isucon/isuumo/webapp/${godir}/${app}
	ssh isucon@$(1) 'sudo systemctl restart ${service}'
	ssh isucon@$(1) 'sudo systemctl status ${service} --no-pager'
endef

# upload2 / upload3 は現構成では通常使わない。i2 / i3 はどちらも MySQL 専有で
# アプリを動かしていないため、バイナリの配布先は web ホストだけでよい。
.PHONY: upload1 upload2 upload3 all zenbu
upload1: build
	$(call upload,i1)
upload2: build
	$(call upload,i2)
upload3: build
	$(call upload,i3)

# 一括デプロイ。アプリが動くのは web ホスト(${web_host})だけなのでそこにだけ配る。
all: upload1
zenbu: all
	make prepare

.PHONY: pbnalp1 pbnalp2 pbnalp3 pbpt1 pbpt2 pbpt3 pbptselect1 pbptselect2 pbptselect3
pbnalp1: ; ssh isucon@i1 -A "cd isuumo/webapp && make nalp" | pbcopy
pbnalp2: ; ssh isucon@i2 -A "cd isuumo/webapp && make nalp" | pbcopy
pbnalp3: ; ssh isucon@i3 -A "cd isuumo/webapp && make nalp" | pbcopy
pbpt1: ; ssh isucon@i1 -A "cd isuumo/webapp && make pt && cat ~/pt.log" | pbcopy
pbpt2: ; ssh isucon@i2 -A "cd isuumo/webapp && make pt && cat ~/pt.log" | pbcopy
pbpt3: ; ssh isucon@i3 -A "cd isuumo/webapp && make pt && cat ~/pt.log" | pbcopy
pbptselect1: ; ssh isucon@i1 -A "cd isuumo/webapp && make ptselect && cat ~/pt.log" | pbcopy
pbptselect2: ; ssh isucon@i2 -A "cd isuumo/webapp && make ptselect && cat ~/pt.log" | pbcopy
pbptselect3: ; ssh isucon@i3 -A "cd isuumo/webapp && make ptselect && cat ~/pt.log" | pbcopy

.PHONY: getpprof
getpprof:
	scp i1:/home/isucon/cpu-profile.prof ./
	go tool pprof -http 127.0.0.1:9092 ./cpu-profile.prof

.PHONY: upmakefile1 upmakefile2 upmakefile3 gp1 gp2 gp3
upmakefile1: ; scp ./Makefile isucon@i1:/home/isucon/isuumo/webapp/Makefile
upmakefile2: ; scp ./Makefile isucon@i2:/home/isucon/isuumo/webapp/Makefile
upmakefile3: ; scp ./Makefile isucon@i3:/home/isucon/isuumo/webapp/Makefile
gp1: ; ssh isucon@i1 -A "cd isuumo/webapp && git pull"
gp2: ; ssh isucon@i2 -A "cd isuumo/webapp && git pull"
gp3: ; ssh isucon@i3 -A "cd isuumo/webapp && git pull"
