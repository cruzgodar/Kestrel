platform :ios, '26.0'
use_frameworks!

target 'Kestrel' do
  pod 'onnxruntime-objc', '~> 1.20'

  # Search paths only, no linking: KestrelTests is injected into the Kestrel
  # app, which already links the pods. It just needs to *see* the
  # onnxruntime_objc module, because `@testable import Kestrel` has to resolve
  # every module the Kestrel swiftmodule depends on.
  target 'KestrelTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
