# shellcheck shell=bash disable=SC2034
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# Ente：sso=none，账号是 Ente 自己的——密码就是端到端加密的根（SRP 登录、主密钥用密码
# 包裹），云吞的身份进不来，所以身份和数据两项都走 Ente 自己的账号体系：用官方 ente CLI
# 在插件网络里直连 museum 注册账号、断言实例管理员，升级和重装后用保存的凭据重新登录，
# 证明账号和密钥材料还在数据里。验证码按 museum.yaml 的 hardcoded-ott（上游自托管开发
# 配置，注册页在网关后面只有主人打得开）固定为 123456，邮箱用 @example.org 结尾。
#
# CLI 二进制按 ente/ente 的 ente-cli-v* 最新正式发布下载并按 SHA256SUMS 校验，缓存和
# CLI 的数据目录（vault）放在状态目录旁边。探针在宿主机上，museum 的网络从外面到不了，
# 所以命令放进插件网络里的一次性容器里跑，镜像取栈里 museum 在用的那个（本地已有，不额外拉）。
#
# 两套 harness：dev 套件（scripts/probes.sh）给 SMOKE_*，e2e（smoke.sh + plugins/ente.sh）
# 给 E2E_*。下面把两套名字归一化；SMOKE_STATE 在 dev 是 .wonton 目录，在 e2e 是一个
# 每次 run 被截空的文件，所以标记和缓存放它旁边的目录，并在标记里记实例名——实例对不上
# （e2e 每次随机新实例、dev 换了栈）就整个重建，不拿旧实例的账号。

if [[ -n "${E2E_INSTANCE:-}" && -z "${SMOKE_INSTANCE:-}" ]]; then
	SMOKE_INSTANCE="$E2E_INSTANCE"
	SMOKE_SLUG="${E2E_SLUG:-}"
fi
SMOKE_INSTANCE="${SMOKE_INSTANCE:-}"
SMOKE_SLUG="${SMOKE_SLUG:-${SMOKE_PLUGIN_ID:-}}"
SMOKE_NOTE="ente 账号与云吞身份独立（端到端加密，sso=none）；探测账号由官方 CLI 经 museum 注册并断言它是实例管理员"
E2E_NOTE="$SMOKE_NOTE"

state_dir() { # 状态旁边建一个自己的目录：SMOKE_STATE 是文件（e2e）时用 <路径>.ente
	if [[ -d "${SMOKE_STATE:-}" ]]; then
		printf '%s' "$SMOKE_STATE/ente"
	else
		printf '%s' "${SMOKE_STATE:-/tmp/ente-smoke}.ente"
	fi
}
ENTE_STATE="$(state_dir)"
ENTE_PROBE_DIR="$ENTE_STATE/probe"
ENTE_CLI_DIR="$ENTE_STATE/cli"
ENTE_MARKER_FILE="$ENTE_PROBE_DIR/marker.env"
ENTE_OTP=123456
ENTE_API="http://museum:8080"

web_assert() { grep -qi 'ente photos'; }   # 标准输入：应用真实页面（<title>）

# —— ente CLI 助手 ——

cli_ensure() { # 把 CLI 下载并校验好（缓存在 ENTE_CLI_DIR，挂进容器就能跑）
	local arch tag base file
	if [[ ! -x "$ENTE_CLI_DIR/ente" ]]; then
		case "$(uname -m)" in
		x86_64) arch=amd64 ;;
		aarch64 | arm64) arch=arm64 ;;
		*) echo "不支持的架构：$(uname -m)"; return 1 ;;
		esac
		mkdir -p "$ENTE_CLI_DIR"
		tag="$(git ls-remote --tags --refs https://github.com/ente/ente 'ente-cli-v*' |
			awk -F/ '{print $NF}' | sort -V | tail -1)"
		[[ -n "$tag" ]] || { echo "列不出 ente-cli 的发布 tag（需要能访问 github.com）"; return 1; }
		base="https://github.com/ente/ente/releases/download/$tag"
		curl -fsSL --retry 3 -o "$ENTE_CLI_DIR/SHA256SUMS" "$base/SHA256SUMS" ||
			{ echo "下载 SHA256SUMS 失败：$tag"; return 1; }
		# 资产名不跟 tag 一致（0.4.0 起是 ente-v…，0.4.1 起是 ente-cli-v…），按校验清单里的 linux 资产取名字，不自己拼。
		file="$(awk -v a="$arch" '$2 ~ ("linux-" a "\\.tar\\.gz$") { print $2; exit }' "$ENTE_CLI_DIR/SHA256SUMS")"
		[[ -n "$file" ]] || { echo "SHA256SUMS 里没有 linux-$arch 的包：$tag"; return 1; }
		curl -fsSL --retry 3 -o "$ENTE_CLI_DIR/$file" "$base/$file" ||
			{ echo "下载 CLI 失败：$base/$file"; return 1; }
		(cd "$ENTE_CLI_DIR" && grep -F "  $file" SHA256SUMS | sha256sum -c --status -) ||
			{ echo "CLI 的 sha256 对不上：$tag"; return 1; }
		tar -xzf "$ENTE_CLI_DIR/$file" -C "$ENTE_CLI_DIR" ente &&
			chmod +x "$ENTE_CLI_DIR/ente" && rm -f "$ENTE_CLI_DIR/$file" "$ENTE_CLI_DIR/SHA256SUMS"
	fi
}

cli_net() { # 插件网络名：从 museum 容器上读。slug/实例在调用时才取（e2e 在 source 钩子之后才注入）
	local slug instance
	slug="${SMOKE_SLUG:-${E2E_SLUG:-${SMOKE_PLUGIN_ID:-}}}"
	instance="${SMOKE_INSTANCE:-${E2E_INSTANCE:-}}"
	[[ -n "$slug" && -n "$instance" ]] ||
		{ echo "拿不到插件 slug 或实例名（SMOKE_SLUG/E2E_SLUG、SMOKE_INSTANCE/E2E_INSTANCE 都没设）"; return 1; }
	docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' \
		"wonton-$instance--$slug--museum" 2>/dev/null
}

cli_image() { # 跑 CLI 的镜像：直接用栈里已经在跑的那个（本地已有，不用再拉；entrypoint 会被 /cli/ente 盖掉）
	local slug instance
	slug="${SMOKE_SLUG:-${E2E_SLUG:-${SMOKE_PLUGIN_ID:-}}}"
	instance="${SMOKE_INSTANCE:-${E2E_INSTANCE:-}}"
	docker inspect -f '{{.Config.Image}}' "wonton-$instance--$slug--museum" 2>/dev/null
}

cli_run() { # 在插件网络里跑一次 CLI（直连 museum，不走网关）
	local net image key=()
	net="$(cli_net)" || { echo "找不到插件网络（museum 容器不在运行？）"; return 1; }
	image="$(cli_image)"
	[[ -n "$image" ]] || { echo "读不出 museum 容器的镜像"; return 1; }
	mkdir -p "$ENTE_PROBE_DIR" && chmod 700 "$ENTE_PROBE_DIR"
	# ENTE_CLI_VAULT_KEY 要的是密钥本身，不是路径；还没有（第一次生成）时不带。
	[[ ! -s "$ENTE_PROBE_DIR/vault-key" ]] || key=(-e "ENTE_CLI_VAULT_KEY=$(cat "$ENTE_PROBE_DIR/vault-key")")
	# 插件网络里没有代理，容器外面的 http_proxy 会让 CLI 绕到不存在的回环地址上（502）。
	docker run --rm -i --network "$net" \
		-v "$ENTE_PROBE_DIR:/probe" -v "$ENTE_CLI_DIR:/cli:ro" \
		-e ENTE_CLI_HOME=/probe/home "${key[@]}" \
		-e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
		--entrypoint /cli/ente "$image" "$@"
}

ente_cli() { # 确保 CLI 就位后再跑：vault key 只在第一次生成
	# 标准输入先读完：cli_ensure、vault key 那几步会把管道里的 --input - 输入吃光。
	local input=""
	[[ -t 0 ]] || input="$(cat)"
	cli_ensure || return 1
	mkdir -p "$ENTE_PROBE_DIR" && chmod 700 "$ENTE_PROBE_DIR"
	if [[ ! -s "$ENTE_PROBE_DIR/vault-key" ]]; then
		(umask 077 && cli_run vault key generate > "$ENTE_PROBE_DIR/vault-key") ||
			{ echo "生成 vault key 失败"; return 1; }
	fi
	if [[ -n "$input" ]]; then
		printf '%s' "$input" | cli_run "$@"
	else
		cli_run "$@"
	fi
}

marker_read() { # 读标记（INSTANCE、MARKER、EMAIL、PASSWORD），没有或实例对不上就返回 1
	[[ -f "$ENTE_MARKER_FILE" ]] || return 1
	local line
	while IFS= read -r line; do
		case "$line" in
		INSTANCE=* | MARKER=* | EMAIL=* | PASSWORD=*) eval "$line" ;;
		esac
	done < "$ENTE_MARKER_FILE"
	[[ -n "${INSTANCE:-}" && -n "${MARKER:-}" && -n "${EMAIL:-}" && -n "${PASSWORD:-}" ]] || return 1
	# 实例对不上（e2e 每次随机新实例，dev 换了栈）就重建，别拿旧实例的账号
	if [[ "$INSTANCE" != "$SMOKE_INSTANCE" ]]; then
		rm -rf "$ENTE_STATE"
		return 1
	fi
}

ensure_account() { # 注册探测账号（幂等）：邮箱带随机标记，凭据和实例名存进标记文件
	local marker email password json out
	if marker_read; then
		return 0
	fi
	marker="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	email="probe-$marker@example.org"
	password="$(head -c 24 /dev/urandom | base64 | tr -d '\n')"
	out="$(ente_cli account request-otp --email "$email" --app photos --host "$ENTE_API" 2>&1)" ||
		{ echo "request-otp 失败：$out"; return 1; }
	json="$(jq -nc --arg e "$email" --arg p "$password" --arg o "$ENTE_OTP" \
		'{email:$e,password:$p,otp:$o}')"
	out="$(printf '%s' "$json" | ente_cli account create --account probe --app photos \
		--host "$ENTE_API" --input - --accept-terms --no-input 2>&1)" ||
		{ echo "创建账号失败：$out"; return 1; }
	(umask 077 && printf 'INSTANCE=%s\nMARKER=%s\nEMAIL=%s\nPASSWORD=%s\n' \
		"$SMOKE_INSTANCE" "$marker" "$email" "$password" > "$ENTE_MARKER_FILE")
}

# —— 探测项 ——

# 身份：探测账号在实例里注册成功、能登录，并且是实例管理员（一次性实例的第一个账号）。
identity_check() {
	ensure_account || return 1
	marker_read || { echo "标记文件读不出来"; return 1; }
	local out
	out="$(ente_cli admin user view "$EMAIL" --account probe --json 2>&1)" ||
		{ echo "admin user view 失败（探测账号不是实例管理员？）：$out"; return 1; }
	grep -qF "$EMAIL" <<<"$out" || { echo "管理员看到的不是探测账号：$out"; return 1; }
}

# 写数据：探测账号本身就是保的数据——邮箱里的随机标记是标记，SRP 参数和密钥材料在
# 实例的 Postgres 里。凭据存进标记文件，data_check 靠它重新登录。
data_write() {
	ensure_account || return 1
	marker_read || { echo "标记文件写不进去"; return 1; }
}

# 查数据：用保存的凭据重新登录（先忘掉本地，SRP 校验完全走实例数据库里的账号数据），
# 登录后的账号邮箱必须还是标记里的那个。非交互登录要带验证码，按 hardcoded-ott 固定值来。
data_check() {
	local json out
	marker_read || { echo "标记文件不见了（data_write 没跑过？）"; return 1; }
	out="$(ente_cli account logout --local --no-input 2>&1)" ||
		{ echo "logout 失败：$out"; return 1; }
	out="$(ente_cli account request-otp --email "$EMAIL" --app photos --purpose login \
		--host "$ENTE_API" 2>&1)" ||
		{ echo "request-otp 失败：$out"; return 1; }
	json="$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" --arg o "$ENTE_OTP" \
		'{email:$e,password:$p,otp:$o}')"
	out="$(printf '%s' "$json" | ente_cli account login --account probe --app photos \
		--host "$ENTE_API" --input - --no-input 2>&1)" ||
		{ echo "重新登录失败（升级/重装后账号数据丢了？）：$out"; return 1; }
	out="$(ente_cli account list --json 2>&1)" ||
		{ echo "account list 失败：$out"; return 1; }
	grep -qF "$EMAIL" <<<"$out" || { echo "登录上的不是标记账号 $EMAIL：$out"; return 1; }
}
