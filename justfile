# Cubicle: common tasks. Run `just` to list them.
#
# The app is ad-hoc signed, so macOS may drop its Accessibility permission after a rebuild or reinstall;
# see `just reset-accessibility`.

app         := "build/Cubicle.app"
cli         := app / "Contents/MacOS/cubicle"
bundle      := "tech.phin.Cubicle"
workflow    := "build/Cubicle.alfredworkflow"
# Signing identity for builds. Defaults to your Developer ID Application certificate, else Apple Development,
# else ad-hoc. Override: `SIGN_IDENTITY="Apple Development: ..." just debug`, or `SIGN_IDENTITY=- just debug`.
export SIGN_IDENTITY := env("SIGN_IDENTITY", `security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ && !d {d=$2} /Apple Development/ && !a {a=$2} END {print d ? d : a}'`)
# Where `just install` puts the app. Override: `just install_dir=~/Applications install`
install_dir := "/Applications"
# Where the cubicle command is linked. Override: `just prefix=/usr/local/bin install`
prefix      := env("HOME") / ".local/bin"

# List the available recipes
default:
    @just --list

# ---- install ----------------------------------------------------------------

# Build release, install to the install dir, link the cubicle command, and launch
install: build quit
    rm -rf "{{install_dir}}/Cubicle.app"
    cp -R "{{app}}" "{{install_dir}}/Cubicle.app"
    mkdir -p "{{prefix}}"
    ln -sf "{{install_dir}}/Cubicle.app/Contents/MacOS/cubicle" "{{prefix}}/cubicle"
    open "{{install_dir}}/Cubicle.app"
    @echo "Installed {{install_dir}}/Cubicle.app and linked {{prefix}}/cubicle."
    @echo "Grant Accessibility to Cubicle if macOS asks. Add {{prefix}} to your PATH to use the cubicle command."

# Remove the installed app and the cubicle link (settings and Space names are kept)
uninstall: quit
    rm -rf "{{install_dir}}/Cubicle.app"
    rm -f "{{prefix}}/cubicle"

# ---- build & test -----------------------------------------------------------

# Build a release Cubicle.app into ./build
build:
    ./dist/build.sh

# Build a debug Cubicle.app (faster; what the dev recipes launch)
debug:
    ./dist/build.sh --debug

# Wipe ./build first, then do a debug build (removes stale files from the bundle)
rebuild:
    ./dist/build.sh --clean --debug

# Run the unit tests
test:
    swift test

# Compile only, no bundle
check:
    swift build

# ---- run --------------------------------------------------------------------

# Quit the running app (no error if it is not running)
quit:
    -osascript -e 'tell application "Cubicle" to quit'
    @sleep 1

# Launch the built app from ./build
open:
    open {{app}}

# Quit and relaunch the built app
relaunch: quit open

# Test, rebuild and relaunch: the normal edit loop
dev: test debug relaunch

# Is it running?
status:
    @pgrep -fl "Cubicle.app" || echo "Cubicle is not running"

# ---- cli --------------------------------------------------------------------

# Run the built cubicle CLI, e.g. `just cli list` or `just cli go innopts`
cli *args:
    {{cli}} {{args}}

# Link the built (./build) CLI onto your PATH, for development
link-cli:
    mkdir -p "{{prefix}}"
    ln -sf "$(pwd)/{{cli}}" "{{prefix}}/cubicle"
    @echo "Linked {{prefix}}/cubicle to the build in ./build"

# Remove the cubicle link
unlink-cli:
    rm -f "{{prefix}}/cubicle"

# ---- signing ----------------------------------------------------------------

# Show how the built app is signed. A stable build says "anchor apple generic ... certificate leaf" with your
# team; an unstable ad-hoc build says "cdhash" (macOS then forgets its Accessibility grant on every rebuild).
signature:
    @codesign -dvv {{app}} 2>&1 | grep -E "^(Identifier|Signature|Authority|TeamIdentifier)|flags="
    @codesign -dr - {{app}} 2>&1 | grep "designated =>"

# Check the signature is valid and unmodified
verify:
    codesign --verify --strict --verbose=2 {{app}}

# ---- alfred -----------------------------------------------------------------

# Package the Alfred workflow into build/Cubicle.alfredworkflow
alfred:
    plutil -lint alfred/info.plist
    mkdir -p build
    rm -f "{{workflow}}"
    cd alfred && zip -qr "../{{workflow}}" . -x '.DS_Store'
    @echo "Built {{workflow}}"

# Import the workflow into Alfred (needs the Powerpack)
alfred-install: alfred
    open "{{workflow}}"

# ---- settings & permissions -------------------------------------------------

# Forget Cubicle's Accessibility grant so macOS asks again (use if shortcuts stop responding after a rebuild)
reset-accessibility:
    tccutil reset Accessibility {{bundle}}

# Copy settings (including Space names) from the upstream InstantSpaceSwitcher bundle ID. Quits the app first.
import-old-settings: quit
    defaults export com.interversehq.InstantSpaceSwitcher - | defaults import {{bundle}} -

# Show the saved Space names
names:
    defaults read {{bundle}} customSpaceNames

# ---- git --------------------------------------------------------------------

# Push the current branch to main on your repo
push:
    git push origin HEAD:main

# What upstream InstantSpaceSwitcher has that Cubicle does not
upstream:
    git fetch upstream
    git log --oneline HEAD..upstream/main
