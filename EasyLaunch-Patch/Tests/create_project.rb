# Creates an isolated simulator harness using the PRODUCTION controllers.
# Firebase/AppsFlyer and Unity runtime calls are replaced only at their boundary.
require 'xcodeproj'
require 'fileutils'

tests = File.expand_path(__dir__)
sources = File.expand_path('../Sources/Classes', tests)
output = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'RoutingTests.xcodeproj'))
app = project.new_target(:application, 'RoutingHost', :ios, '15.0')
suite = project.new_target(:unit_test_bundle, 'RoutingTests', :ios, '15.0')
suite.add_dependency(app)
app.add_file_references([project.main_group.new_file(File.join(tests, 'Stubs/TestHost.m'))])
production = %w[CustomAppController.mm PreloadViewController.mm NotificationPromptViewController.m WebViewController.m WebViewConfig.m]
suite.add_file_references(production.map { |name| project.main_group.new_file(File.join(sources, name)) })
suite.add_file_references(%w[RoutingTests.m Stubs/RuntimeStubs.m].map { |name| project.main_group.new_file(File.join(tests, name)) })
[app, suite].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "club.easylaunch.tests.#{target.name}",
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGNING_ALLOWED' => 'NO',
      'CLANG_ENABLE_OBJC_ARC' => 'YES',
      'GCC_ENABLE_OBJC_EXCEPTIONS' => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'UNITY_USES_REMOTE_NOTIFICATIONS=0'],
      'HEADER_SEARCH_PATHS' => ['$(inherited)', "\"#{tests}/Stubs\"", "\"#{sources}\""],
      'TARGETED_DEVICE_FAMILY' => '1,2'
    })
  end
end
app_plist = File.join(output, 'Host-Info.plist')
Xcodeproj::Plist.write_to_path({
  'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
  'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
  'CFBundleName' => '$(PRODUCT_NAME)',
  'CFBundlePackageType' => 'APPL',
  'CFBundleVersion' => '1',
  'CFBundleShortVersionString' => '1.0',
  'UILaunchScreen' => {},
  'NSAppTransportSecurity' => {'NSAllowsLocalNetworking' => true}
}, app_plist)
app.build_configurations.each do |config|
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = app_plist
end
suite.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/RoutingHost.app/RoutingHost'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
%w[UIKit WebKit UserNotifications].each { |framework| suite.add_system_framework(framework) }
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(suite)
scheme.add_test_target(suite)
scheme.set_launch_target(app)
scheme.save_as(project.path, 'RoutingTests', true)
project.save
puts project.path
