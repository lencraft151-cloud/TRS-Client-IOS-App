# Erzeugt das eingecheckte Xcode-Projekt der iOS-App: src-tauri/gen/apple/trs-launcher.xcodeproj
#
#   gem install xcodeproj      # einmalig (läuft auch unter Linux/Windows, kein Mac nötig)
#   ruby scripts/ios/generate-xcodeproj.rb
#
# Aufbau wie die Tauri-Vorlage (`tauri ios init`), aber ohne Abhängigkeit vom Tauri-CLI:
# Die Build-Phase „Build Rust Code“ ruft scripts/build-rust.sh auf, „Embed Game Engine“ legt die Spiel-Engine
# in die App. Signatur über Signing.xcconfig (Team, Bundle-ID, Profil, Entitlements).
# Dazu die Widget-Erweiterung TRSWidgets (Widget „Zuletzt gespielt“, Live-Aktivität; Widgets/) und im App-Target die
# Kurzbefehle für Siri (Sources/trs-launcher/Shortcuts.swift) – beide lesen Shared/TrsShared.swift.
# Version aus src-tauri/tauri.conf.json – nach einem Versionssprung das Skript erneut ausführen.
require 'json'
require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
APPLE = File.join(ROOT, 'src-tauri/gen/apple')
PROJECT_PATH = File.join(APPLE, 'trs-launcher.xcodeproj')
TARGET_NAME = 'trs-launcher_iOS'
DEPLOYMENT_TARGET = '15.0'
WIDGET_NAME = 'TRSWidgets'
# containerBackground, App Intents: iOS 17. Auf älteren Systemen läuft die App ohne Widget.
WIDGET_DEPLOYMENT_TARGET = '17.0'

conf = JSON.parse(File.read(File.join(ROOT, 'src-tauri/tauri.conf.json')))
version = conf.fetch('version')
product_name = conf.fetch('productName')
alternate_icons = Dir[File.join(APPLE, 'Assets.xcassets/AppIcon-*.appiconset')].map { |p| File.basename(p, '.appiconset') }.sort

# Vorläufige IDs fortlaufend statt zufällig: `predictabilize_uuids` (unten) bildet die endgültigen IDs aus dem Pfad
# jedes Objekts, und darin stehen auch IDs als Text (Zielabhängigkeit App → Widget). Mit zufälligen vorläufigen IDs
# käme bei jedem Lauf ein anderes Projekt heraus – und die CI-Prüfung „Projekt aktuell“ schlüge fehl.
module SequentialUUIDs
  def generate_uuid
    @sequential_uuid = (@sequential_uuid || 0) + 1
    format('%024X', @sequential_uuid)
  end
end
Xcodeproj::Project.prepend(SequentialUUIDs)

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
shortcuts_swift = app_sources.new_file('Shortcuts.swift')
app_sources.new_group('bindings', 'bindings').new_file('bindings.h')
assets = project.main_group.new_file('Assets.xcassets')
launch = project.main_group.new_file('LaunchScreen.storyboard')
support = project.main_group.new_group(TARGET_NAME, TARGET_NAME)
support.new_file('Info.plist')
support.new_file("#{TARGET_NAME}.entitlements")
support.new_file("#{TARGET_NAME}-basic.entitlements")
shared = project.main_group.new_group('Shared', 'Shared')
shared_swift = shared.new_file('TrsShared.swift')
widgets = project.main_group.new_group('Widgets', 'Widgets')
widget_swift = widgets.new_file('TRSWidgets.swift')
widgets.new_file('Info.plist')
widgets.new_file("#{WIDGET_NAME}.entitlements")
widgets.new_file("#{WIDGET_NAME}-basic.entitlements")
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
widget = project.new_target(:app_extension, WIDGET_NAME, :ios, WIDGET_DEPLOYMENT_TARGET, nil, :swift, WIDGET_NAME)
# Konfigurationen heißen wie bei Tauri klein (debug/release) – build-rust.sh und Externals/ hängen daran.
[project, target, widget].each do |owner|
  owner.build_configurations.each { |c| c.name = c.name.downcase }
  owner.build_configuration_list.default_configuration_name = 'release'
end
target.add_file_references([main_mm, shortcuts_swift, shared_swift])
target.resources_build_phase.add_file_reference(assets)
target.resources_build_phase.add_file_reference(launch)
widget.add_file_references([widget_swift, shared_swift])

# Frameworks wie in der Tauri-Vorlage; die Swift-Teile der Plugins stecken in libapp.a (Autolink).
# Pfade relativ zum SDK (nicht zur Xcode-Version), damit das Projekt mit jedem Xcode baut.
[target, widget].each do |t|
  t.frameworks_build_phase.files.to_a.each { |f| f.file_ref&.remove_from_project; f.remove_from_project }
end
project.frameworks_group.children.to_a.each(&:remove_from_project)
def link_sdk_frameworks(project, target, names)
  names.each do |name|
    ref = project.frameworks_group.files.find { |f| f.name == "#{name}.framework" }
    unless ref
      ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{name}.framework", :sdk_root)
      ref.name = "#{name}.framework"
      ref.last_known_file_type = 'wrapper.framework'
    end
    target.frameworks_build_phase.add_file_reference(ref)
  end
end
link_sdk_frameworks(project, target, %w[CoreGraphics Metal MetalKit QuartzCore Security UIKit WebKit])
link_sdk_frameworks(project, widget, %w[ActivityKit SwiftUI WidgetKit])

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
    # ActivityKit (Live-Aktivität, iOS 16.1) und App Intents (Siri, iOS 16) schwach: Die App startet auch unter iOS 15.
    'OTHER_LDFLAGS' => '$(inherited) -lapp -weak_framework ActivityKit -weak_framework AppIntents',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES' => alternate_icons.join(' '),
    'SUPPORTS_MACCATALYST' => 'NO',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    # Shortcuts.swift: Swift-5-Modus (keine strikte Nebenläufigkeitsprüfung von Swift 6).
    'SWIFT_VERSION' => '5.0'
  )
end

# Widget-Erweiterung: Team, Signaturart und App-Gruppe aus Signing.xcconfig, Bundle-ID = die der App + „.widgets“
# ($(inherited) ist der Wert aus Signing.xcconfig bzw. Signing.local.xcconfig – so passt sie auch zu einer eigenen
# Bundle-ID). Bei manueller Signatur braucht sie ein eigenes Profil (TRS_WIDGET_PROFILE) oder ein Wildcard-Profil.
widget.build_configurations.each do |config|
  config.base_configuration_reference = signing
  s = config.build_settings
  %w[CODE_SIGN_IDENTITY CODE_SIGN_IDENTITY[sdk=iphoneos*] DEVELOPMENT_TEAM PRODUCT_BUNDLE_IDENTIFIER CODE_SIGN_STYLE
     ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME].each { |k| s.delete(k) }
  s.merge!(
    'PRODUCT_NAME' => WIDGET_NAME,
    'PRODUCT_BUNDLE_IDENTIFIER' => '$(inherited).widgets',
    'INFOPLIST_FILE' => 'Widgets/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => '$(TRS_WIDGET_ENTITLEMENTS)',
    'PROVISIONING_PROFILE_SPECIFIER' => '$(TRS_WIDGET_PROFILE)',
    'MARKETING_VERSION' => version,
    'CURRENT_PROJECT_VERSION' => version,
    'IPHONEOS_DEPLOYMENT_TARGET' => WIDGET_DEPLOYMENT_TARGET,
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SWIFT_VERSION' => '5.0',
    'SKIP_INSTALL' => 'YES',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'ENABLE_BITCODE' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
    'SUPPORTS_MACCATALYST' => 'NO',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO'
  )
end

# Erweiterung in die App (PlugIns/) – Xcode baut sie über die Abhängigkeit vor der App.
embed = target.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
embed_file = embed.add_file_reference(widget.product_reference, true)
embed_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
target.add_dependency(widget)

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
