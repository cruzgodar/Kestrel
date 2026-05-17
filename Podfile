platform :ios, '26.0'
use_frameworks!

target 'Kestrel' do
  pod 'onnxruntime-objc', '~> 1.20'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
