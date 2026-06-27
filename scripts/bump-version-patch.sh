#!/usr/bin/env bash
# 将 VERSION 的末位 patch +1，并同步到 project.yml + Docs/appcast.xml，随后 git add。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VFILE="$ROOT/VERSION"
v=$(tr -d '[:space:]' < "$VFILE")
major=$(echo "$v" | cut -d. -f1)
minor=$(echo "$v" | cut -d. -f2)
patch=$(echo "$v" | cut -d. -f3)
if [ -z "$patch" ]; then patch=0; fi
patch=$((patch + 1))
newv="$major.$minor.$patch"
printf '%s\n' "$newv" > "$VFILE"
bash "$ROOT/scripts/sync-version.sh"

# 同步 Docs/appcast.xml（Sparkle 自动更新 feed）
# 从 git commit 自动生成更新内容（与 CI release.yml 逻辑一致）
APPLECAST="$ROOT/Docs/appcast.xml"
if [ -f "$APPLECAST" ]; then
  PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

  # 获取上一个 tag，生成 changelog
  PREV_TAG=$(cd "$ROOT" && git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
  if [ -n "$PREV_TAG" ]; then
    CHANGELOG=$(cd "$ROOT" && git log "$PREV_TAG"..HEAD --pretty=format:"- %s (%h)" --no-merges | head -30)
  else
    CHANGELOG="- Initial release"
  fi

  # 生成 <li> 列表
  ITEMS=""
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^- //')
    [ -n "$line" ] && ITEMS="${ITEMS}          <li>${line}</li>
"
  done <<< "$CHANGELOG"

  # 构建 description CDATA 块
  DESC="        <h3>WaifuX $newv</h3>
        <ul>
${ITEMS}        </ul>"

  # 用 Python 重写整个 appcast.xml（避免 sed 处理特殊字符问题）
  cd "$ROOT" && python3 -c "
import sys

version = sys.argv[1]
pub_date = sys.argv[2]
desc = sys.argv[3]

xml = '''<?xml version=\"1.0\" encoding=\"utf-8\"?>
<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
  <channel>
    <title>WaifuX</title>
    <link>https://jipika.github.io/WaifuX/appcast.xml</link>
    <description>WaifuX Updates</description>
    <language>zh</language>
    <item>
      <title>Version {version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <pubDate>{pub_date}</pubDate>
      <description><![CDATA[
{desc}
      ]]></description>
      <enclosure
        url=\"https://github.com/jipika/WaifuX/releases/download/v{version}/WaifuX.dmg\"
        type=\"application/octet-stream\"
        length=\"0\"
      />
    </item>
  </channel>
</rss>'''.format(version=version, pub_date=pub_date, desc=desc)

with open('Docs/appcast.xml', 'w') as f:
    f.write(xml)
" "$newv" "$PUB_DATE" "$DESC"

  echo "Synced appcast.xml -> $newv (changelog from $PREV_TAG)" >&2
fi

cd "$ROOT" && git add VERSION project.yml Docs/appcast.xml
echo "githooks: 合并自动递增版本 -> $newv" >&2
