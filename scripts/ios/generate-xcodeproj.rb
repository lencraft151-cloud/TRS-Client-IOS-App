# Erzeugt das eingecheckte Xcode-Projekt der iOS-App: src-tauri/gen/apple/trs-launcher.xcodeproj
#
#   gem install xcodeproj      # einmalig (läuft auch unter Linux/Windows, kein Mac nötig)
#   ruby scripts/ios/generate-xcodeproj.rb
#
# Aufbau wie die Tauri-Vorlage (`tauri ios init`), aber ohne Abhängigkeit vom Tauri-CLI:
# Die Build-Phase „Build Rust Code“ ruft scripts/build-rust.sh auf, „Embed Game Engine“ legt die Spiel-Engine
# in die App. Signatur über Signing.xcconfig (Team, Bundle-ID, Profil, Entitlements).
# Version aus src-tauri/tauri.conf.json – nach einem Versionssprung das Skript erneut ausführen.
require 'json'
require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
APPLE = File.join(ROOT, 'src-tauri/gen/apple')
PROJECT_PATH = File.join(APPLE, 'trs-launcher.xcodeproj')
TARGET_NAME = 'trs-launcher_iOS'
DEPLOYMENT_TARGET = '15.0'

conf = JSON.parse(File.read(File.join(ROOT, 'src-tauri/tauri.conf.json')))
version = conf.fetch('version')
product_name = conf.fetch('productName')
alternate_icons = Dir[File.join(APPLE, 'Assets.xcassets/AppIcon-*.appiconset')].map { |p| File.basename(p, '.appiconset') }.sort

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH, false, 56)
# Stand Xcode 27: sonst bietet Xcode „Update to recommended settings“ an – das würde u. a. die Skript-Sandbox
# einschalten, und die Build-Phasen (Rust, Engine-Download) liefen nicht mehr.
XCODE_VERSION = '2700'
project.root_object.attributes['LastUpgradeCheck'] = XCODE_VERSION
project.root_object.attributes['LastSwiftUpdateCheck'] = XCODE_VERSION
project.root_object.attributes['BuildIndependentTargetsInParallel'] = 'YES'
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base]

# --- Dateien ---
sources = project.main_group.new_group('Sources', 'Sources')
app_sources = sources.new_group('trs-launcher', 'trs-launcher')
main_mm = app_sources.new_file('main.mm')
app_sources.new_group('bindings', 'bindings').new_file('bindings.h')
assets = project.main_group.new_file('Assets.xcassets')
launch = project.main_group.new_file('LaunchScreen.storyboard')
support = project.main_group.new_group(TARGET_NAME, TARGET_NAME)
support.new_file('Info.plist')
support.new_file("#{TARGET_NAME}.entitlements")
support.new_file("#{TARGET_NAME}-basic.entitlements")
signing = project.main_group.new_file('Signing.xcconfig')
project.main_group.new_file('UpdateChannel.xcconfig')
scripts = project.main_group.new_group('scripts', 'scripts')
scripts.new_file('build-rust.sh')
scripts.new_file('embed-engine.sh')
lldb_group = project.main_group.new_group('lldb', 'lldb')
lldb_group.new_file('trs-jit.lldbinit')
lldb_group.new_file('trs_jit.py')
%w[ExportOptions-development.plist ExportOptions-ad-hoc.plist ExportOptions-enterprise.plist].each do |name|
  project.main_group.new_file(name)
end

# --- Target ---
target = project.new_target(:application, TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :objc, product_name)
# Konfigurationen heißen wie bei Tauri klein (debug/release) – build-rust.sh und Externals/ hängen daran.
[project, target].each do |owner|
  owner.build_configurations.each { |c| c.name = c.name.downcase }
  owner.build_configuration_list.default_configuration_name = 'release'
end
target.add_file_references([main_mm])
target.resources_build_phase.add_file_reference(assets)
target.resources_build_phase.add_file_reference(launch)

# Frameworks wie in der Tauri-Vorlage; die Swift-Teile der Plugins stecken in libapp.a (Autolink).
# Pfade relativ zum SDK (nicht zur Xcode-Version), damit das Projekt mit jedem Xcode baut.
target.frameworks_build_phase.files.to_a.each { |f| f.file_ref&.remove_from_project; f.remove_from_project }
project.frameworks_group.children.to_a.each(&:remove_from_project)
%w[CoreGraphics Metal MetalKit QuartzCore Security UIKit WebKit].each do |name|
  ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{name}.framework", :sdk_root)
  ref.name = "#{name}.framework"
  ref.last_known_file_type = 'wrapper.framework'
  target.frameworks_build_phase.add_file_reference(ref)
end

rust = target.new_shell_script_build_phase('Build Rust Code')
rust.shell_path = '/bin/bash'
rust.shell_script = "bash \"${PROJECT_DIR}/scripts/build-rust.sh\"\n"
rust.output_paths = ['$(SRCROOT)/Externals/arm64/${CONFIGURATION}/libapp.a']
rust.always_out_of_date = '1'
target.build_phases.move(rust, 0)

engine = target.new_shell_script_build_phase('Embed Game Engine')
engine.shell_path = '/bin/bash'
engine.shell_script = "bash \"${PROJECT_DIR}/scripts/embed-engine.sh\"\n"
engine.always_out_of_date = '1'

swift_paths = '$(SDKROOT)/usr/lib/swift $(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$(PLATFORM_NAME) ' \
              '$(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/$(PLATFORM_NAME)'
target.build_configurations.each do |config|
  config.base_configuration_reference = signing
  s = config.build_settings
  # Signatur kommt aus Signing.xcconfig – hier nichts festlegen, sonst überschreibt das Target die Datei.
  %w[CODE_SIGN_IDENTITY CODE_SIGN_IDENTITY[sdk=iphoneos*] DEVELOPMENT_TEAM PRODUCT_BUNDLE_IDENTIFIER CODE_SIGN_STYLE
     ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME].each { |k| s.delete(k) }
  s.merge!(
    'PRODUCT_NAME' => product_name,
    'INFOPLIST_FILE' => "#{TARGET_NAME}/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => '$(TRS_ENTITLEMENTS)',
    'MARKETING_VERSION' => version,
    'CURRENT_PROJECT_VERSION' => version,
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'ARCHS' => 'arm64',
    'VALID_ARCHS' => 'arm64',
    'EXCLUDED_ARCHS[sdk=iphoneos*]' => 'x86_64',
    'ENABLE_BITCODE' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES' => 'YES',
    'LIBRARY_SEARCH_PATHS[arch=arm64]' => "$(inherited) $(PROJECT_DIR)/Externals/arm64/$(CONFIGURATION) #{swift_paths}",
    'LIBRARY_SEARCH_PATHS[arch=x86_64]' => "$(inherited) $(PROJECT_DIR)/Externals/x86_64/$(CONFIGURATION) #{swift_paths}",
    'OTHER_LDFLAGS' => '$(inherited) -lapp',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES' => alternate_icons.join(' '),
    'SUPPORTS_MACCATALYST' => 'NO',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO'
  )
end

# Feste UUIDs: erneutes Erzeugen ändert das Projekt nur, wenn sich wirklich etwas ändert.
project.predictabilize_uuids
project.save

# --- Gemeinsames Schema (Run = debug, Archive = release) ---
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, nil, launch_target: true)
scheme.launch_action.build_configuration = 'debug'
scheme.test_action.build_configuration = 'debug'
scheme.analyze_action.build_configuration = 'debug'
scheme.profile_action.build_configuration = 'release'
scheme.archive_action.build_configuration = 'release'
scheme.launch_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'RUST_BACKTRACE', value: 'full', enabled: true },
  { key: 'RUST_LOG', value: 'info', enabled: true },
  # JIT beim Start aus Xcode: Debugger bleibt angehängt (iOS 26/TXM), siehe lldb/trs_jit.py.
  { key: 'TRS_JIT_ALWAYS_ATTACHED', value: '1', enabled: true }
])
# ▶ Run = JIT für Minecraft Java: LLDB lässt JVM-Signale durch und beantwortet die JIT-Anfragen der Engine.
scheme.launch_action.xml_element.attributes['customLLDBInitFile'] = '$(SRCROOT)/lldb/trs-jit.lldbinit'
scheme.doc.root.attributes['LastUpgradeVersion'] = XCODE_VERSION
scheme.save_as(PROJECT_PATH, TARGET_NAME, true)

# --- Workspace (das öffnet man in Xcode; im Xcode-Paket von scripts/ios/package-xcode.sh liegt er oben) ---
workspace_path = File.join(APPLE, 'TRS-Launcher.xcworkspace')
FileUtils.rm_rf(workspace_path)
Xcodeproj::Workspace.new(Xcodeproj::Workspace::FileReference.new('trs-launcher.xcodeproj', 'group')).save_as(workspace_path)
settings = File.join(workspace_path, 'xcshareddata')
FileUtils.mkdir_p(settings)
File.write(File.join(settings, 'WorkspaceSettings.xcsettings'), <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  	<key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key>
  	<false/>
  </dict>
  </plist>
PLIST

puts "#{PROJECT_PATH} (#{product_name} #{version}, alternative Symbole: #{alternate_icons.join(', ')})"
puts workspace_path
