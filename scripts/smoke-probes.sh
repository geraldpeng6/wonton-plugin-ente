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
# CLI 的数据目录（vault）都放在 $SMOKE_STATE 下。命令在插件网络里的一次性 alpine 容器里
# 运行：探针在宿主机上，museum 的网络从外面到不了。

ENTE_OTP=123456
ENTE_API="http://museum:8080"
ENTE_PROBE_DIR="${SMOKE_STATE:-/tmp}/ente-probe"
ENTE_MARKER_FILE="$ENTE_PROBE_DIR/marker.env"
ENTE_CLI_DIR="${SMOKE_STATE:-/tmp}/ente-cli"

web_assert() { grep -qi 'ente photos'; }   # 标准输入：应用真实页面（<title>）

# —— ente CLI 助手 ——

cli_ensure() { # 把 CLI 下载并校验好（缓存在 $SMOKE_STATE/ente-cli，挂进容器就能跑）
	local arch tag url
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
		url="https://github.com/ente/ente/releases/download/$tag/ente-cli-$tag-linux-$arch.tar.gz"
		curl -fsSL --retry 3 -o "$ENTE_CLI_DIR/cli.tar.gz" "$url" ||
			{ echo "下载 CLI 失败：$url"; return 1; }
		curl -fsSL --retry 3 -o "$ENTE_CLI_DIR/SHA256SUMS" \
			"https://github.com/ente/ente/releases/download/$tag/SHA256SUMS" ||
			{ echo "下载 SHA256SUMS 失败：$tag"; return 1; }
		(cd "$ENTE_CLI_DIR" &&
			grep "ente-cli-$tag-linux-$arch.tar.gz" SHA256SUMS | sha256sum -c --status -) ||
			{ echo "CLI 的 sha256 对不上：$tag"; return 1; }
		tar -xzf "$ENTE_CLI_DIR/cli.tar.gz" -C "$ENTE_CLI_DIR" ente &&
			chmod +x "$ENTE_CLI_DIR/ente" && rm -f "$ENTE_CLI_DIR/cli.tar.gz" "$ENTE_CLI_DIR/SHA256SUMS"
	fi
}

cli_net() { # 插件网络名：从 museum 容器上读
	docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' \
		"wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--museum" 2>/dev/null
}

ente_cli() { # 在插件网络里跑一次 CLI（直连 museum，不走网关）
	local net
	cli_ensure || return 1
	net="$(cli_net)" || { echo "找不到插件网络（museum 容器不在运行？）"; return 1; }
	mkdir -p "$ENTE_PROBE_DIR" && chmod 700 "$ENTE_PROBE_DIR"
	if [[ ! -s "$ENTE_PROBE_DIR/vault-key" ]]; then
		(umask 077 && docker run --rm --network "$net" \
			-v "$ENTE_PROBE_DIR:/probe" -v "$ENTE_CLI_DIR:/cli:ro" \
			-e ENTE_CLI_HOME=/probe/home -e ENTE_CLI_VAULT_KEY=/probe/vault-key \
			--entrypoint /cli/ente alpine:3.20 vault key generate > "$ENTE_PROBE_DIR/vault-key") ||
			{ echo "生成 vault key 失败"; return 1; }
	fi
	docker run --rm --network "$net" \
		-v "$ENTE_PROBE_DIR:/probe" -v "$ENTE_CLI_DIR:/cli:ro" \
		-e ENTE_CLI_HOME=/probe/home -e ENTE_CLI_VAULT_KEY=/probe/vault-key \
		--entrypoint /cli/ente alpine:3.20 "$@"
}

marker_read() { # 读标记（MARKER、EMAIL、PASSWORD），没有就返回 1
	[[ -f "$ENTE_MARKER_FILE" ]] || return 1
	local line
	while IFS= read -r line; do
		case "$line" in
		MARKER=* | EMAIL=* | PASSWORD=*) eval "$line" ;;
		esac
	done < "$ENTE_MARKER_FILE"
	[[ -n "${MARKER:-}" && -n "${EMAIL:-}" && -n "${PASSWORD:-}" ]]
}

ensure_account() { # 注册探测账号（幂等）：邮箱带随机标记，凭据存进 $SMOKE_STATE
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
	(umask 077 && printf 'MARKER=%s\nEMAIL=%s\nPASSWORD=%s\n' \
		"$marker" "$email" "$password" > "$ENTE_MARKER_FILE")
}

# —— 探测项 ——

# 身份：探测账号在实例里注册成功、能登录，并且是实例管理员（一次性实例的第一个账号）。
SMOKE_NOTE="ente 账号与云吞身份独立（端到端加密，sso=none）；探测账号由官方 CLI 经 museum 注册并断言它是实例管理员"
identity_check() {
	ensure_account || return 1
	marker_read || { echo "标记文件读不出来"; return 1; }
	local out
	out="$(ente_cli admin user view "$EMAIL" --account probe --json 2>&1)" ||
		{ echo "admin user view 失败（探测账号不是实例管理员？）：$out"; return 1; }
	grep -qF "$EMAIL" <<<"$out" || { echo "管理员看到的不是探测账号：$out"; return 1; }
}

# 写数据：探测账号本身就是保的数据——邮箱里的随机标记是标记，SRP 参数和密钥材料在
# 实例的 Postgres 里。凭据存进 $SMOKE_STATE，data_check 靠它重新登录。
data_write() {
	ensure_account || return 1
	marker_read || { echo "标记文件写不进去"; return 1; }
}

# 查数据：用保存的凭据重新登录（先忘掉本地，SRP 校验完全走实例数据库里的账号数据），
# 登录后的账号邮箱必须还是标记里的那个。
data_check() {
	local json out
	marker_read || { echo "标记文件不见了（data_write 没跑过？）"; return 1; }
	json="$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')"
	out="$(ente_cli account logout --local --no-input 2>&1)" ||
		{ echo "logout 失败：$out"; return 1; }
	out="$(printf '%s' "$json" | ente_cli account login --account probe --app photos \
		--host "$ENTE_API" --input - --no-input 2>&1)" ||
		{ echo "重新登录失败（升级/重装后账号数据丢了？）：$out"; return 1; }
	out="$(ente_cli account list --json 2>&1)" ||
		{ echo "account list 失败：$out"; return 1; }
	grep -qF "$EMAIL" <<<"$out" || { echo "登录上的不是标记账号 $EMAIL：$out"; return 1; }
}
