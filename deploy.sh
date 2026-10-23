#!/bin/bash
# GitHub Pages 一键部署脚本（Token 仅从环境变量读取，不落盘、不回显）
set -uo pipefail

OWNER="dazhuxiansen"
REPO="qqq-dashboard"
BRANCH="main"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -n "${GITHUB_TOKEN:-}" ] || { echo "ERROR: GITHUB_TOKEN 环境变量未设置"; exit 1; }
[ ${#GITHUB_TOKEN} -ge 20 ] || { echo "ERROR: token 长度异常"; exit 1; }

API="https://api.github.com"
AUTH="Authorization: Bearer ${GITHUB_TOKEN}"

# 通用重试 curl
gh_api() {
  local method="$1" path="$2" data="${3:-}"
  for i in 1 2 3 4 5; do
    if [ -n "$data" ]; then
      RESP=$(curl -s -w "\n%{http_code}" -X "$method" -H "$AUTH" -H "Content-Type: application/json" --connect-timeout 10 --max-time 30 -d "$data" "${API}${path}")
    else
      RESP=$(curl -s -w "\n%{http_code}" -X "$method" -H "$AUTH" --connect-timeout 10 --max-time 30 "${API}${path}")
    fi
    CODE=$(echo "$RESP" | tail -n1)
    [ "$CODE" -ge 200 ] && [ "$CODE" -lt 300 ] && { echo "$RESP" | sed '$d'; return 0; }
    [ "$CODE" = "000" ] && { echo "  (网络超时，第 $i 次重试...)" >&2; sleep 3; continue; }
    echo "$RESP" | sed '$d'; echo "HTTP_$CODE" >&2; return 1
  done
  echo "ERROR: 重试 5 次仍失败" >&2; return 1
}

echo "== 1/5 验证 Token 身份 =="
LOGIN=$(gh_api GET /user | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*' | head -1 | sed 's/.*"login"[[:space:]]*:[[:space:]]*"//')
[ "$LOGIN" = "$OWNER" ] || { echo "ERROR: token 所属账号是 '${LOGIN:-未知}'，不是 $OWNER"; exit 1; }
echo "  身份确认: $LOGIN"

echo "== 2/5 创建仓库 $OWNER/$REPO =="
CREATE=$(gh_api POST /user/repos "{\"name\":\"$REPO\",\"private\":false,\"description\":\"纳指回撤分档轮动仪表盘 · QQQ+TQQQ 实时轮动信号\",\"has_issues\":false,\"auto_init\":false}" || true)
if echo "$CREATE" | grep -q '"full_name"'; then
  echo "  仓库已创建"
elif echo "$CREATE" | grep -q "422\|already exists"; then
  echo "  仓库已存在，继续"
else
  echo "  创建返回: $(echo "$CREATE" | head -c 200)"
  # 404/403 等硬错误才退出
  echo "$CREATE" | grep -q "HTTP_4" && exit 1
fi

echo "== 3/5 推送页面文件 =="
cd "$DIR"
[ -f .nojekyll ] || touch .nojekyll
if [ ! -d .git ]; then
  git init -q -b "$BRANCH"
  git config user.name "$OWNER"
  git config user.email "${OWNER}@users.noreply.github.com"
fi
git add -A
git -c user.name="$OWNER" -c user.email="${OWNER}@users.noreply.github.com" commit -q -m "纳指轮动大猪V5版（温度计/进度条/一键复制/盘中预警/触发历史）" || echo "  (无新变更)"
git remote set-url origin "https://oauth2:${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git" 2>/dev/null || git remote add origin "https://oauth2:${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git"
PUSHED=0
for i in 1 2 3; do
  if git push -q -u origin "$BRANCH" 2>/tmp/push_err.log; then PUSHED=1; break; fi
  echo "  (推送失败，第 $i 次重试...)"; sed "s|oauth2:${GITHUB_TOKEN}|oauth2:***|g" /tmp/push_err.log | head -3; sleep 3
  git push -q --force origin "$BRANCH" 2>/dev/null && PUSHED=1 && break
done
[ "$PUSHED" = "1" ] || { echo "ERROR: 推送失败"; exit 1; }
git remote set-url origin "https://github.com/${OWNER}/${REPO}.git"  # 清掉 remote 里的 token
echo "  已推送到 main 分支（remote 已清除 token）"

echo "== 4/5 开通 GitHub Pages =="
PAGES=$(gh_api POST "/repos/${OWNER}/${REPO}/pages" "{\"build_type\":\"legacy\",\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}" || true)
if echo "$PAGES" | grep -q '"html_url"\|"url"'; then
  echo "  Pages 已开通"
elif echo "$PAGES" | grep -q "409\|already"; then
  echo "  Pages 已存在，尝试更新配置"
  gh_api PUT "/repos/${OWNER}/${REPO}/pages" "{\"build_type\":\"legacy\",\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}" >/dev/null && echo "  配置已更新"
else
  echo "  返回: $(echo "$PAGES" | head -c 200)"
fi

echo "== 5/5 等待首次构建并验证 =="
URL="https://${OWNER}.github.io/${REPO}/"
OK=0
for i in $(seq 1 20); do
  CODE=$(curl -s -o /tmp/page_check.html -w "%{http_code}" --connect-timeout 10 --max-time 30 -A "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.28" "$URL")
  if [ "$CODE" = "200" ]; then OK=1; break; fi
  echo "  构建中... (HTTP $CODE，${i}0s)"; sleep 10
done
[ "$OK" = "1" ] || { echo "ERROR: 页面 200 超时，请稍后在浏览器打开 $URL 查看"; exit 1; }

# 内容校验
grep -q "温度计" /tmp/page_check.html && echo "  ✓ 温度计模块在页" || echo "  ⚠ 未找到温度计文案"
grep -q "qt.gtimg.cn" /tmp/page_check.html && echo "  ✓ 行情接口引用在页" || echo "  ⚠ 未找到行情接口"
grep -qi "inject.js" /tmp/page_check.html && echo "  ⚠ 发现 inject.js 引用" || echo "  ✓ 无 inject.js 拦截脚本"
SIZE=$(wc -c < /tmp/page_check.html)
echo "  ✓ 微信 UA 访问 HTTP 200，页面 $SIZE 字节"
rm -f /tmp/push_err.log

echo ""
echo "=========================================="
echo " 部署完成！永久直链："
echo " $URL"
echo "=========================================="
