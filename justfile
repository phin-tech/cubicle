# Cubicle: common tasks. Run `just` to list them.
#
# Builds go through Xcode (project.yml -> Cubicle.xcodeproj, into ./build/xcode). Signing comes from
# Signing.local.xcconfig (gitignored; see Signing.xcconfig). With a real team the app's identity is the same on
# every build, so macOS keeps its Accessibility permission across rebuilds; ad-hoc signing loses it each time.

# Release recipes (doctor, notes, ship, ...), from apple-template. Run `just --list`.
import 'release.just'

derived     := "build/xcode"
# The Debug app: what the dev recipes (relaunch, cli, signature) use.
app         := derived / "Build/Products/Debug/Cubicle.app"
release_app := derived / "Build/Products/Release/Cubicle.app"
cli         := app / "Contents/Helpers/cubicle"
bundle      := "tech.phin.Cubicle"
workflow    := "build/Cubicle.alfredworkflow"
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
    cp -R "{{release_app}}" "{{install_dir}}/Cubicle.app"
    mkdir -p "{{prefix}}"
    ln -sf "{{install_dir}}/Cubicle.app/Contents/Helpers/cubicle" "{{prefix}}/cubicle"
    open "{{install_dir}}/Cubicle.app"
    @echo "Installed {{install_dir}}/Cubicle.app and linked {{prefix}}/cubicle."
    @echo "Grant Accessibility to Cubicle if macOS asks. Add {{prefix}} to your PATH to use the cubicle command."

# Remove the installed app and the cubicle link (settings and Space names are kept)
uninstall: quit
    rm -rf "{{install_dir}}/Cubicle.app"
    rm -f "{{prefix}}/cubicle"

# ---- build & test -----------------------------------------------------------

# Regenerate Cubicle.xcodeproj from project.yml (the project is gitignored)
gen:
    xcodegen generate --use-cache

# Build the Release app (universal) into ./build/xcode
build: gen
    xcodebuild -quiet -project Cubicle.xcodeproj -scheme Cubicle -configuration Release -derivedDataPath {{derived}} build

# Build the Debug app (what the dev recipes launch)
debug: gen
    xcodebuild -quiet -project Cubicle.xcodeproj -scheme Cubicle -configuration Debug -derivedDataPath {{derived}} build

# Delete ./build/xcode
clean:
    rm -rf {{derived}}

# Clean, then do a Debug build
rebuild: clean debug

# Run the unit tests (SwiftPM)
test:
    swift test

# Compile the package only, no app
check:
    swift build

# ---- run --------------------------------------------------------------------

# Quit the running app (no error if it is not running)
quit:
    -osascript -e 'tell application "Cubicle" to quit'
    @sleep 1

# Launch the Debug app from ./build/xcode
open:
    open {{app}}

# Quit and relaunch the Debug app
relaunch: quit open

# Test, rebuild and relaunch: the normal edit loop
dev: test debug relaunch

# Is it running?
status:
    @pgrep -fl "Cubicle.app" || echo "Cubicle is not running"

# Forget that the walkthrough was shown, then relaunch the Debug app to see it again
onboarding: quit
    -defaults delete {{bundle}} onboardingCompleted
    open {{app}}

# ---- cli --------------------------------------------------------------------

# Run the Debug build's cubicle CLI, e.g. `just cli list` or `just cli go innopts`
cli *args:
    {{cli}} {{args}}

# Link the Debug build's CLI onto your PATH, for development
link-cli:
    mkdir -p "{{prefix}}"
    ln -sf "$(pwd)/{{cli}}" "{{prefix}}/cubicle"
    @echo "Linked {{prefix}}/cubicle to the Debug build in ./build/xcode"

# Remove the cubicle link
unlink-cli:
    rm -f "{{prefix}}/cubicle"

# ---- signing ----------------------------------------------------------------

# Show how an app is signed (default: the Debug build). "cdhash" means ad-hoc: macOS forgets its Accessibility grant each rebuild
signature path=app:
    @codesign -dvv {{path}} 2>&1 | grep -E "^(Identifier|Signature|Authority|TeamIdentifier)|flags="
    @codesign -dr - {{path}} 2>&1 | grep "designated =>"

# Check an app's signature is valid and unmodified (default: the Debug build)
verify path=app:
    codesign --verify --strict --verbose=2 {{path}}

# ---- icons ------------------------------------------------------------------

# Rebuild Resources/AppIcon.icns from the master art in assets/
icons:
    ./dist/make-icns.sh assets/AppIcon-1024.png Resources/AppIcon.icns

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
