#!/bin/bash
# author: Junjie.M

DEFAULT_GITHUB_API_URL=https://github.com
DEFAULT_MARKETPLACE_API_URL=https://marketplace.dify.ai
DEFAULT_PIP_MIRROR_URL=https://mirrors.aliyun.com/pypi/simple

GITHUB_API_URL="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-$DEFAULT_MARKETPLACE_API_URL}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-$DEFAULT_PIP_MIRROR_URL}"

CURR_DIR=`dirname $0`
cd $CURR_DIR || exit 1
CURR_DIR=`pwd`
USER=`whoami`
ARCH_NAME=`uname -m`
OS_TYPE=$(uname)
OS_TYPE=$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')

CMD_NAME="dify-plugin-${OS_TYPE}-amd64"
if [[ "arm64" == "$ARCH_NAME" || "aarch64" == "$ARCH_NAME" ]]; then
	CMD_NAME="dify-plugin-${OS_TYPE}-arm64"
fi

# Cross packaging / resolution controls
PIP_PLATFORM=""
RAW_PLATFORM=""    # raw value from -p, e.g. manylinux2014_x86_64
PACKAGE_SUFFIX="offline"
PRERELEASE_ALLOW=0

market(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" market [plugin author] [plugin name] [plugin version]"
		echo "Example:"
		echo "	"$0" market junjiem mcp_sse 0.0.1"
		echo "	"$0" market langgenius agent 0.0.9"
		echo ""
		exit 1
	fi
	PLUGIN_AUTHOR=$2
	PLUGIN_NAME=$3
	PLUGIN_VERSION=$4
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_AUTHOR}-${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg
	PLUGIN_DOWNLOAD_URL=${MARKETPLACE_API_URL}/api/v1/plugins/${PLUGIN_AUTHOR}/${PLUGIN_NAME}/${PLUGIN_VERSION}/download

	echo ""
	echo "=========================================="
	echo "Downloading from Dify Marketplace"
	echo "=========================================="
	echo "Author: ${PLUGIN_AUTHOR}"
	echo "Plugin: ${PLUGIN_NAME}"
	echo "Version: ${PLUGIN_VERSION}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the plugin author, name, and version"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

github(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" github [Github repo] [Release title] [Assets name (include .difypkg suffix)]"
		echo "Example:"
		echo "	"$0" github junjiem/dify-plugin-tools-dbquery v0.0.2 db_query.difypkg"
		echo "	"$0" github https://github.com/junjiem/dify-plugin-agent-mcp_sse 0.0.1 agent-mcp_see.difypkg"
		echo ""
		exit 1
	fi
	GITHUB_REPO=$2
	if [[ "${GITHUB_REPO}" != "${GITHUB_API_URL}"* ]]; then
		GITHUB_REPO="${GITHUB_API_URL}/${GITHUB_REPO}"
	fi
	RELEASE_TITLE=$3
	ASSETS_NAME=$4
	PLUGIN_NAME="${ASSETS_NAME%.difypkg}"
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_NAME}-${RELEASE_TITLE}.difypkg
	PLUGIN_DOWNLOAD_URL=${GITHUB_REPO}/releases/download/${RELEASE_TITLE}/${ASSETS_NAME}

	echo ""
	echo "=========================================="
	echo "Downloading from GitHub"
	echo "=========================================="
	echo "Repository: ${GITHUB_REPO}"
	echo "Release: ${RELEASE_TITLE}"
	echo "Asset: ${ASSETS_NAME}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the GitHub repo, release title, and asset name"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

_local(){
	echo $2
	if [[ -z "$2" ]]; then
		echo ""
		echo "Usage: "$0" local [difypkg path]"
		echo "Example:"
		echo "	"$0" local ./db_query.difypkg"
		echo "	"$0" local /root/dify-plugin/db_query.difypkg"
		echo ""
		exit 1
	fi
	PLUGIN_PACKAGE_PATH=`realpath $2`
	repackage ${PLUGIN_PACKAGE_PATH}
}

repackage(){
	local PACKAGE_PATH=$1
	PACKAGE_NAME_WITH_EXTENSION=`basename ${PACKAGE_PATH}`
	PACKAGE_NAME="${PACKAGE_NAME_WITH_EXTENSION%.*}"

	echo ""
	echo "=========================================="
	echo "Dify Plugin Repackaging Tool"
	echo "=========================================="
	echo "Source: ${PACKAGE_PATH}"
	echo "Work directory: ${CURR_DIR}/${PACKAGE_NAME}"

	# Extract plugin package
	echo ""
	echo "Extracting plugin package..."
	install_unzip
	unzip -o ${PACKAGE_PATH} -d ${CURR_DIR}/${PACKAGE_NAME}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Failed to extract package"
		exit 1
	fi
	echo "✓ Package extracted successfully"

	cd ${CURR_DIR}/${PACKAGE_NAME} || exit 1
	if [ ! -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
		echo "⚠ Warning: No pyproject.toml or requirements.txt found"
	fi

	# Inject [tool.uv] config into pyproject.toml (runtime will use local wheels offline)
	inject_uv_into_pyproject() {
		local PYFILE="$1"
		[ -f "$PYFILE" ] || return 0
	awk '
		BEGIN { in_uv=0; saw_uv=0; saw_no=0; saw_find=0; saw_pre=0 }
		function print_missing(){ if (!saw_no) print "no-index = true"; if (!saw_find) print "find-links = [\"./wheels\"]"; if (!saw_pre) print "prerelease = \"allow\"" }
		/^[ \t]*\[tool\.uv\][ \t]*$/ { saw_uv=1; in_uv=1; saw_no=0; saw_find=0; saw_pre=0; print; next }
		{ if (in_uv && $0 ~ /^[ \t]*\[/) { print_missing(); in_uv=0 } }
		{ if (in_uv && $0 ~ /^[ \t]*no-index[ \t]*=/) { print "no-index = true"; saw_no=1; next } }
		{ if (in_uv && $0 ~ /^[ \t]*find-links[ \t]*=/) { print "find-links = [\"./wheels\"]"; saw_find=1; next } }
		{ if (in_uv && $0 ~ /^[ \t]*prerelease[ \t]*=/) { print "prerelease = \"allow\""; saw_pre=1; next } }
		{ print }
		END {
			if (in_uv) { print_missing() }
			if (!saw_uv) {
				print ""
				print "[tool.uv]"
				print "no-index = true"
				print "find-links = [\"./wheels\"]"
				print "prerelease = \"allow\""
			}
		}
		' "$PYFILE" > "$PYFILE.tmp" && mv "$PYFILE.tmp" "$PYFILE"
		echo "Injected [tool.uv] into $PYFILE"
	}

	if python3 -m pip --version &> /dev/null 2>&1; then
		PIP_CMD="python3 -m pip"
	elif command -v pip &> /dev/null && pip --version &> /dev/null 2>&1; then
		PIP_CMD=pip
	elif command -v pip3 &> /dev/null && pip3 --version &> /dev/null 2>&1; then
		PIP_CMD=pip3
	else
		echo "pip not found. Install: python3 -m ensurepip --upgrade"
		exit 1
	fi
	echo "✓ Using pip: ${PIP_CMD}"

	# ============================================
	# Step 1: Detect Python and platform configuration
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 1: Detecting Python and platform"
	echo "=========================================="

	# Detect Python version
	PYTHON_CMD_FOR_UV="python3"
	PY_VERSION_FULL=$(python3 --version 2>&1 | awk '{print $2}')
	PY_MAJOR=$(echo $PY_VERSION_FULL | cut -d. -f1)
	PY_MINOR=$(echo $PY_VERSION_FULL | cut -d. -f2)
	PYTHON_VERSION=$PY_VERSION_FULL

	echo "Detected Python: $PYTHON_VERSION"

	# If Python is 3.14+, try to use 3.12 or 3.13 for better compatibility
	if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge 14 ]; then
		echo "⚠ Warning: Python $PYTHON_VERSION is too new for some packages"
		if command -v python3.12 &> /dev/null; then
			PYTHON_CMD_FOR_UV="python3.12"
			PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
			echo "✓ Switched to python3.12 ($PYTHON_VERSION) for better compatibility"
		elif command -v python3.13 &> /dev/null; then
			PYTHON_CMD_FOR_UV="python3.13"
			PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
			echo "✓ Switched to python3.13 ($PYTHON_VERSION) for better compatibility"
		else
			echo "⚠ Warning: No compatible Python version found, proceeding with $PYTHON_VERSION"
		fi
	else
		echo "✓ Python version $PYTHON_VERSION is compatible"
	fi

	# Extract Python major.minor for uv
	UV_PY_VERSION=$($PYTHON_CMD_FOR_UV - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)

	# Determine uv target platform to avoid cross-platform dependency conflicts
	local UV_PLATFORM=""
	if [[ -n "$RAW_PLATFORM" ]]; then
		case "$RAW_PLATFORM" in
			*linux*|*manylinux* )
				UV_PLATFORM="linux"
				echo "Target platform: Linux (cross-compilation from $OS_TYPE)"
				;;
			*macos*|*darwin* )
				UV_PLATFORM="macos"
				echo "Target platform: macOS (cross-compilation from $OS_TYPE)"
				;;
			*win* )
				UV_PLATFORM="windows"
				echo "Target platform: Windows (cross-compilation from $OS_TYPE)"
				;;
			* )
				UV_PLATFORM=""
				echo "Target platform: current ($OS_TYPE)"
				;;
		esac
	else
		if [[ "$OS_TYPE" == "darwin" ]]; then
			UV_PLATFORM="macos"
		elif [[ "$OS_TYPE" == "linux" ]]; then
			UV_PLATFORM="linux"
		elif [[ "$OS_TYPE" == "windows" ]]; then
			UV_PLATFORM="windows"
		fi
		echo "Target platform: $UV_PLATFORM (current system)"
	fi

	# Set prerelease flag
	UV_PRERELEASE_FLAG=""
	if [[ "$PRERELEASE_ALLOW" -eq 1 ]]; then
		UV_PRERELEASE_FLAG="--prerelease=allow"
		echo "Prerelease versions: allowed"
	else
		echo "Prerelease versions: disallowed"
	fi

	# Keep uv's resolution Python version aligned with pip download's target.
	# Otherwise uv may pin transitive versions whose target-Python wheels do
	# not exist (e.g. gevent==25.5.1 for cp313 only), and pip download fails
	# or — worse — silently produces an incomplete ./wheels/ for Dify.
	if [[ -n "$PIP_TARGET_PY_VERSION" && "$UV_PLATFORM" == "linux" ]]; then
		if [[ "$UV_PY_VERSION" != "$PIP_TARGET_PY_VERSION" ]]; then
			echo "ℹ Aligning uv resolution python ($UV_PY_VERSION → $PIP_TARGET_PY_VERSION) with target"
			UV_PY_VERSION="$PIP_TARGET_PY_VERSION"
		fi
	fi

	echo "✓ Configuration: platform=${UV_PLATFORM:-current}, python=$UV_PY_VERSION"

	# ============================================
	# Step 2: Generate requirements.txt from pyproject.toml
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 2: Processing dependencies"
	echo "=========================================="

	# Strip dev dependency groups from pyproject.toml so that uv / plugin_daemon
	# never attempts to resolve dev-only packages (black, pytest, ruff, etc.)
	strip_dev_dependency_groups() {
		local PYFILE="$1"
		[ -f "$PYFILE" ] || return 0
		python3 - "$PYFILE" <<'PYSTRIP'
import sys, re

pyfile = sys.argv[1]
with open(pyfile, "r", encoding="utf-8") as f:
    content = f.read()

# Remove [dependency-groups] section entirely.
# This covers both inline tables and multi-line arrays.
# Pattern: match [dependency-groups] header up to the next [section] or EOF.
content = re.sub(
    r'\n*\[dependency-groups\]\s*\n(?:(?!\n\[)[^\n]*\n)*',
    '\n',
    content
)

# Also remove any [tool.uv.dev-dependencies] section (older style)
content = re.sub(
    r'\n*\[tool\.uv\.dev-dependencies\]\s*\n(?:(?!\n\[)[^\n]*\n)*',
    '\n',
    content
)

# Remove dev-dependencies key if inline under [tool.uv]
content = re.sub(
    r'\n[ \t]*dev-dependencies[ \t]*=[ \t]*\[.*?\]',
    '',
    content,
    flags=re.DOTALL
)

with open(pyfile, "w", encoding="utf-8") as f:
    f.write(content)
PYSTRIP
	}

	if [ -f "pyproject.toml" ]; then
		echo "Stripping dev dependency groups from pyproject.toml..."
		strip_dev_dependency_groups "pyproject.toml"
		echo "✓ Dev dependency groups removed"

# Force runtime deps to exact versions for Dify/plugin_daemon uv sync
python3 - <<'PYFIXDEPS'
from pathlib import Path
import re

p = Path("pyproject.toml")
if p.exists():
    text = p.read_text(encoding="utf-8")

    new_deps = "dependencies = [\n" \
        "    \"dify_plugin==0.7.4\",\n" \
        "    \"gevent==25.5.1\",\n" \
        "    \"greenlet==3.2.5\",\n" \
        "    \"openai==2.32.0\",\n" \
        "    \"setuptools==80.9.0\",\n" \
        "]"

    text, n = re.subn(
        r'dependencies\s*=\s*\[(?:.|\n)*?\]',
        new_deps,
        text,
        count=1
    )

    if n == 0:
        raise SystemExit("未找到 dependencies = [...]，请检查 pyproject.toml 结构")

    p.write_text(text, encoding="utf-8")
PYFIXDEPS
	fi

	# IMPORTANT: We must ALWAYS regenerate requirements.txt from pyproject.toml
	# when pyproject.toml is present, even if the plugin shipped a
	# requirements.txt of its own. Marketplace plugins (e.g.
	# langgenius/openai_api_compatible) ship a requirements.txt that lists
	# only top-level deps (dify_plugin, openai, setuptools). If we trust
	# that file, pip later resolves transitives at *download time* against
	# the host platform, and the resulting ./wheels/ dir is missing wheels
	# (e.g. gevent for Linux) that Dify needs at install time.
	#
	# By running `uv lock` + `uv export --no-dev` against the target Python
	# version and platform, we get a fully pinned, transitive requirements
	# list (dify-plugin==0.7.2, gevent==25.5.1, greenlet==..., etc.) which
	# `pip download` can then materialize wheel-by-wheel for the target.
	if [ -f "pyproject.toml" ]; then
		if command -v uv &> /dev/null; then
			if [ -f "requirements.txt" ]; then
				mv requirements.txt requirements.txt.original
				echo "ℹ Found shipped requirements.txt; backed up as requirements.txt.original"
				echo "  (regenerating with full transitive lock from pyproject.toml)"
			fi

			echo "Generating uv.lock file..."
			uv lock --python "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG}
			if [[ $? -ne 0 ]]; then
				echo "✗ Error: uv lock failed"
				exit 1
			fi
			echo "✓ uv.lock generated successfully"

			echo "Exporting requirements.txt from uv.lock (no-dev, fully pinned)..."
			uv export --format requirements-txt -o requirements.txt --no-dev \
				--python "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG}
			if [[ $? -ne 0 ]]; then
				echo "✗ Error: uv export failed"
				exit 1
			fi
			echo "✓ requirements.txt generated successfully"
python3 - <<'PYFIX'
from pathlib import Path
import re

p = Path("requirements.txt")
text = p.read_text(encoding="utf-8")

# 1) 把 greenlet 错锁版本修正成可用版本
text = text.replace("greenlet==3.4.0", "greenlet==3.2.5")

# 2) 删除所有 uv 导出的 hash continuation 行，否则改版本后哈希一定不匹配
text = re.sub(r' \\\n(?:\s*--hash=[^\n]+\n)+', '\n', text)

p.write_text(text, encoding="utf-8")
PYFIX
sed -i 's/greenlet==3.4.0/greenlet==3.2.5/g' requirements.txt
grep -q "greenlet==" requirements.txt || echo "greenlet==3.2.5" >> requirements.txt
		else
			echo "✗ Error: pyproject.toml found but uv is not installed"
			echo "  Please install uv: pip install uv"
			exit 1
		fi
	elif [ -f "requirements.txt" ]; then
		echo "✓ Using existing requirements.txt (no pyproject.toml found)"
	fi

	[ ! -f "requirements.txt" ] && echo "✗ Error: requirements.txt not found" && exit 1

	# ============================================
	# Step 3: Download Python dependencies as wheels
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 3: Downloading dependencies"
	echo "=========================================="
	echo "Index URL: ${PIP_MIRROR_URL}"
	[ -n "$PIP_PLATFORM" ] && echo "Platform: ${RAW_PLATFORM}"

	mkdir -p ./wheels
	echo "Downloading wheels to ./wheels/..."

	# When --platform is specified, pip requires --python-version,
	# otherwise it defaults to the host interpreter and may pick wheels
	# with the wrong ABI tag (e.g. cp313 instead of cp312).
	PIP_PY_VERSION_FLAG=""
	if [[ -n "$PIP_PLATFORM" ]]; then
		PIP_PY_VERSION_FLAG="--python-version ${PIP_TARGET_PY_VERSION}"
		echo "Target: platform=${RAW_PLATFORM}, python=${PIP_TARGET_PY_VERSION}"
	fi

	${PIP_CMD} download ${PIP_PLATFORM} ${PIP_PY_VERSION_FLAG} -r requirements.txt -d ./wheels \
		--index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Failed to download dependencies"
		echo "  Hint: a transitive dep may not publish wheels for"
		echo "        ${RAW_PLATFORM} / Python ${PIP_TARGET_PY_VERSION}."
		echo "        Try a different -p value or pin a different version"
		echo "        of the offending package in pyproject.toml."
		exit 1
	fi

	# Count downloaded wheels
	WHEEL_COUNT=$(ls -1 ./wheels/*.whl 2>/dev/null | wc -l)
	echo "✓ Downloaded $WHEEL_COUNT wheel packages"

	# Work around plugin_daemon uv 0.9.26 offline resolution of conditional deps.
	# Even Linux-irrelevant marker deps (e.g. gevent -> cffi on win32) may need
	# local candidates present, otherwise uv marks gevent unusable.
	echo "Downloading fallback marker-only dependencies for plugin_daemon uv..."
	${PIP_CMD} download ${PIP_PLATFORM} ${PIP_PY_VERSION_FLAG} -d ./wheels \
		cffi==1.17.1 pycparser==2.22 colorama==0.4.6 \
		--index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Failed to download fallback marker dependencies"
		exit 1
	fi
	echo "✓ Fallback marker dependencies downloaded"

	# Now that wheels exist, inject offline [tool.uv] config for runtime use
	if [ -f "pyproject.toml" ]; then
		echo ""
		echo "Injecting offline [tool.uv] configuration for packaged runtime..."
		inject_uv_into_pyproject "pyproject.toml"
		echo "✓ Offline [tool.uv] configuration injected"
	fi

	# ============================================
	# Step 3.5: Verify every requirements.txt entry has a wheel
	# ============================================
	# This is what makes the difference between "package builds" and
	# "Dify can actually install it". If a transitive dep has no wheel
	# in ./wheels/, uv inside Dify fails with:
	#   "depends on X==N.N.N, we can conclude that Y cannot be used."
	echo ""
	echo "Verifying wheel coverage against requirements.txt..."
	MISSING_WHEELS=$(python3 - <<'PYVERIFY'
import os, re, sys

req_path = "requirements.txt"
wheels_dir = "./wheels"

if not os.path.isfile(req_path):
    sys.exit(0)

# pkg_name -> normalized form (PEP 503)
def norm(n):
    return re.sub(r"[-_.]+", "-", n).lower()

# Parse requirements.txt: lines like "name==version ; marker" or "name==version"
needed = {}
with open(req_path, encoding="utf-8") as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        # Skip requirements that are only needed on Windows
        if 'sys_platform == "win32"' in line or "sys_platform == 'win32'" in line:
            continue

        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*==\s*([A-Za-z0-9_.\-+!]+)", line)
        if m:
            needed[norm(m.group(1))] = m.group(2)

# Inventory wheels: filenames like name-version-...whl
present = set()
if os.path.isdir(wheels_dir):
    for fn in os.listdir(wheels_dir):
        if not fn.endswith(".whl"):
            continue
        # split off the first two segments name-version
        parts = fn.split("-")
        if len(parts) >= 2:
            present.add(norm(parts[0]))
        # sdist fallback (.tar.gz) handled below

    for fn in os.listdir(wheels_dir):
        if fn.endswith(".tar.gz") or fn.endswith(".zip"):
            base = fn.rsplit("-", 1)[0]
            present.add(norm(base))

missing = [n for n in needed if n not in present]
for m in missing:
    print(m)
PYVERIFY
)

	if [[ -n "$MISSING_WHEELS" ]]; then
		echo "✗ Error: the following packages are listed in requirements.txt"
		echo "  but have no matching wheel in ./wheels/ for the target"
		echo "  platform (${RAW_PLATFORM}, py${PIP_TARGET_PY_VERSION}):"
		echo "$MISSING_WHEELS" | sed 's/^/    - /'
		echo ""
		echo "  Dify will fail to install this plugin. Aborting."
		exit 1
	fi
	REQ_COUNT=$(grep -c -E '^[A-Za-z0-9_.\-]+\s*==' requirements.txt 2>/dev/null || echo "?")
	echo "✓ All ${REQ_COUNT} pinned requirements.txt entries have matching wheels"

	# ============================================
	# Step 4: Update requirements.txt for offline usage
	# ============================================
	echo ""
	echo "Updating requirements.txt for offline installation..."
	if [[ "linux" == "$OS_TYPE" ]]; then
		sed -i '1i\--no-index --find-links=./wheels/' requirements.txt
		[ -f ".difyignore" ] && IGNORE_PATH=.difyignore || IGNORE_PATH=.gitignore
		[ -f "$IGNORE_PATH" ] && sed -i '/^wheels\//d' "${IGNORE_PATH}"
	elif [[ "darwin" == "$OS_TYPE" ]]; then
		sed -i ".bak" '1i\--no-index --find-links=./wheels/' requirements.txt && rm -f requirements.txt.bak
		[ -f ".difyignore" ] && IGNORE_PATH=.difyignore || IGNORE_PATH=.gitignore
		[ -f "$IGNORE_PATH" ] && sed -i ".bak" '/^wheels\//d' "${IGNORE_PATH}" && rm -f "${IGNORE_PATH}.bak"
	fi
	echo "✓ requirements.txt updated for offline mode"

	# ============================================
	# Step 5: Package the plugin
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 4: Packaging plugin"
	echo "=========================================="

	cd ${CURR_DIR} || exit 1
	chmod 755 ${CURR_DIR}/${CMD_NAME}

	OUTPUT_PACKAGE="${CURR_DIR}/${PACKAGE_NAME}-${PACKAGE_SUFFIX}.difypkg"
	echo "Packaging: ${PACKAGE_NAME}"
	echo "Output: ${OUTPUT_PACKAGE}"
	echo "Max size: 5120 MB"

	${CURR_DIR}/${CMD_NAME} plugin package ${CURR_DIR}/${PACKAGE_NAME} \
		-o ${OUTPUT_PACKAGE} --max-size 5120
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Packaging failed"
		exit 1
	fi

	# Get file size
	FILE_SIZE=$(du -h "${OUTPUT_PACKAGE}" | cut -f1)
	echo ""
	echo "=========================================="
	echo "✓ Package created successfully!"
	echo "=========================================="
	echo "Location: ${OUTPUT_PACKAGE}"
	echo "Size: ${FILE_SIZE}"
	echo "Platform: ${RAW_PLATFORM:-current}"
}

install_unzip(){
	if ! command -v unzip &> /dev/null; then
		echo "Installing unzip ..."
		yum -y install unzip
		if [ $? -ne 0 ]; then
			echo "Install unzip failed."
			exit 1
		fi
	fi
}

print_usage() {
	echo "usage: $0 [-p platform] [-s package_suffix] [-R] {market|github|local}"
	echo "-p platform: python packages' platform. Using for crossing repacking.
        For example: -p manylinux2014_x86_64 or -p manylinux2014_aarch64"
	echo "-s package_suffix: The suffix name of the output offline package.
        For example: -s linux-amd64 or -s linux-arm64"
	echo "-R: allow pre-release versions during uv resolution (maps to --prerelease=allow)"
	exit 1
}

while getopts "p:s:R" opt; do
	case "$opt" in
		p) RAW_PLATFORM="${OPTARG}"; PIP_PLATFORM="--platform ${OPTARG} --only-binary=:all:" ;;
		s) PACKAGE_SUFFIX="${OPTARG}" ;;
		R) PRERELEASE_ALLOW=1 ;;
		*) print_usage; exit 1 ;;
	esac
done

# Dify's plugin runtime is ALWAYS Linux x86_64 + CPython 3.12.
# If the user did not pass -p, force the wheel download to target that
# platform tree. Otherwise, on a Windows/macOS/non-3.12 host, pip would grab
# host-only wheels for transitive deps (e.g. gevent) and Dify could not
# resolve them, producing errors like:
#   "depends on gevent==25.5.1, we can conclude that dify-plugin==0.7.2
#    cannot be used."
if [[ -z "$RAW_PLATFORM" ]]; then
	RAW_PLATFORM="manylinux2014_x86_64"
	# Pass several --platform tags so pip accepts the broadest set of
	# manylinux wheels that Dify's runtime can install.
	PIP_PLATFORM="--platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux2_17_x86_64 --platform linux_x86_64 --only-binary=:all:"
	echo "ℹ No -p given; defaulting target to Linux (manylinux2014_x86_64) for Dify"
fi

# Force the cross-target Python version to match Dify's runtime (3.12).
# This is what pip uses to pick wheel ABI tags (cp312-...).
PIP_TARGET_PY_VERSION="${PIP_TARGET_PY_VERSION:-3.12}"

shift $((OPTIND - 1))

echo "$1"
case "$1" in
	'market')
	market $@
	;;
	'github')
	github $@
	;;
	'local')
	_local $@
	;;
	*)

print_usage
exit 1
esac
exit 0
