require 'xcodeproj'
require 'fileutils'

# Получаем параметры из командной строки
if ARGV.length < 3
    puts "Usage: ruby add_notification_extension_service.rb <project.xcodeproj> <main_target_name> <extension_target_name> [bundle_id]"
    exit 1
end

project_path = ARGV[0]
main_target_name = ARGV[1]
target_name = ARGV[2]
bundle_id = ARGV[3] || "com.yourcompany.app.#{target_name.downcase}"

# 1. Создаем папку и файлы на диске
project_dir = File.dirname(project_path)
folder_name = File.join(project_dir, target_name)
rel_folder = target_name
FileUtils.mkdir_p(folder_name)

# Определяем путь к исходным файлам в репозитории патча
script_dir = File.dirname(__FILE__)
patch_root = File.expand_path('..', script_dir)
source_swift = File.join(patch_root, 'Sources', 'NotificationService.swift')

# Проверяем наличие исходного файла
unless File.exist?(source_swift)
    puts "ERROR: NotificationService.swift не найден в Sources/"
    exit 1
end

# Копируем NotificationService.swift из Sources/
FileUtils.cp(source_swift, File.join(folder_name, "NotificationService.swift"))

# Содержимое Info.plist
plist_content = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>NotificationService</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.usernotifications.service</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).NotificationService</string>
	</dict>
</dict>
</plist>
XML

File.write(File.join(folder_name, "Info.plist"), plist_content)

# 2. Интеграция в Xcode
project = Xcodeproj::Project.open(project_path)

# Получаем bundle id родительского приложения для создания правильного bundle id extension'а
app_target = project.targets.find { |t| t.name == main_target_name }
if app_target
    parent_bundle_id = app_target.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
    if parent_bundle_id && bundle_id == "com.yourcompany.app.#{target_name.downcase}"
        bundle_id = "#{parent_bundle_id}.#{target_name}"
        puts "ℹ️  Автоматически установлен bundle_id: #{bundle_id}"
    end
end

# Проверяем, существует ли уже таргет с таким именем
existing_target = project.targets.find { |t| t.name == target_name }

if existing_target
    puts "⚠ Таргет '#{target_name}' уже существует. Удаляем старый таргет..."
    
    # Находим главный таргет приложения
    app_target = project.targets.find { |t| t.name == main_target_name }
    
    if app_target
        # Удаляем зависимость от extension таргета
        app_target.dependencies.delete_if { |dep| dep.target == existing_target }
        
        # Удаляем из Embed App Extensions фазы
        app_target.copy_files_build_phases.each do |phase|
            if phase.name == 'Embed App Extensions'
                phase.files.delete_if { |f| f.file_ref == existing_target.product_reference }
            end
        end
    end
    
    # Удаляем старый таргет
    existing_target.remove_from_project
    puts "✓ Старый таргет удален"
end

# Создаем группу в проекте
group = project.main_group.find_subpath(rel_folder, true)
group.set_source_tree('<group>')
group.set_path(rel_folder)

# Очищаем группу от старых файлов если они есть
group.clear

# Добавляем ссылки на файлы (используем имена файлов относительно группы)
file_swift = group.new_reference("NotificationService.swift")
file_swift.set_source_tree('<group>')

file_plist = group.new_reference("Info.plist")
file_plist.set_source_tree('<group>')

# Создаем таргет (тип :app_extension)
extension_target = project.new_target(:app_extension, target_name, :ios, '15.0')

# Добавляем Swift файл в Sources Build Phase таргета
source_build_phase = extension_target.source_build_phase
source_build_phase.add_file_reference(file_swift)

# ВАЖНО: Info.plist НЕ добавляем в Resources Build Phase!
# Он должен быть указан только в INFOPLIST_FILE build setting

# Добавляем системный фреймворк UserNotifications
frameworks_group = project.main_group.find_subpath('Frameworks', true)
frameworks_group.set_source_tree('<group>')

# Добавляем системный фреймворк UserNotifications.framework
user_notifications_ref = frameworks_group.new_reference('System/Library/Frameworks/UserNotifications.framework')
user_notifications_ref.name = 'UserNotifications.framework'
user_notifications_ref.source_tree = 'SDKROOT'

frameworks_build_phase = extension_target.frameworks_build_phase
frameworks_build_phase.add_file_reference(user_notifications_ref)

# Добавляем Firebase SPM packages (если они есть в проекте)
# Ищем Firebase package products
firebase_package = project.root_object.package_references.find { |p| p.repositoryURL =~ /firebase-ios-sdk/i }

if firebase_package
    # Добавляем FirebaseMessaging
    messaging_product = extension_target.package_product_dependencies.find { |p| p.product_name == 'FirebaseMessaging' }
    unless messaging_product
        # Создаем package product dependency
        messaging_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
        messaging_dep.product_name = 'FirebaseMessaging'
        messaging_dep.package = firebase_package
        extension_target.package_product_dependencies << messaging_dep
        puts "✓ FirebaseMessaging добавлен к extension"
    end
    
    # Добавляем FirebaseCore
    core_product = extension_target.package_product_dependencies.find { |p| p.product_name == 'FirebaseCore' }
    unless core_product
        core_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
        core_dep.product_name = 'FirebaseCore'
        core_dep.package = firebase_package
        extension_target.package_product_dependencies << core_dep
        puts "✓ FirebaseCore добавлен к extension"
    end
else
    puts "⚠ Firebase SPM package не найден в проекте (добавьте через SPM если нужно)"
end

# Настройка Build Settings
extension_target.build_configurations.each do |config|
    config.build_settings['PRODUCT_NAME'] = target_name
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
    config.build_settings['INFOPLIST_FILE'] = "#{rel_folder}/Info.plist"
    config.build_settings['SKIP_INSTALL'] = 'YES'
    config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if config.name == 'Debug'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
end

# 3. Привязка к основному приложению (Main App)
app_target = project.targets.find { |t| t.name == main_target_name }

if app_target
    # Добавляем зависимость от extension таргета
    app_target.add_dependency(extension_target)
    
    # Создаем или находим Embed App Extensions фазу
    embed_phase = app_target.copy_files_build_phases.find { |p| p.name == 'Embed App Extensions' }
    unless embed_phase
        embed_phase = app_target.new_copy_files_build_phase('Embed App Extensions')
        embed_phase.dst_subfolder_spec = '13'  # 13 = Plug-Ins (для App Extensions)
    end
    
    # Проверяем, не добавлен ли уже extension в эту фазу
    already_embedded = embed_phase.files.any? { |f| f.file_ref == extension_target.product_reference }
    
    if already_embedded
        puts "⚠ Extension уже добавлен в Embed App Extensions фазу"
    else
        # Добавляем продукт extension в фазу встраивания
        build_file = embed_phase.add_file_reference(extension_target.product_reference)
        build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
        puts "✓ Extension добавлен к таргету #{main_target_name}"
    end
else
    puts "WARNING: Основной таргет '#{main_target_name}' не найден"
end

project.save
puts "✓ Notification Service Extension создан и подключен!"
puts "✓ Файлы скопированы из Sources/ в #{folder_name}"
