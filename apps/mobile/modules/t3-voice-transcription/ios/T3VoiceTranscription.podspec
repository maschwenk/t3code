Pod::Spec.new do |s|
  s.name = 'T3VoiceTranscription'
  s.version = '1.0.0'
  s.summary = 'Local recording conversion and on-device Parakeet for T3 Code dictation.'
  s.author = 'T3 Tools'
  s.homepage = 'https://t3tools.com'
  s.platform = :ios, '18.0'
  s.source = { :path => '.' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.source_files = '*.swift'
  s.frameworks = 'AudioToolbox'
  # React Native's Podfile hooks define spm_dependency; standalone podspec tooling does not.
  if defined?(spm_dependency)
    spm_dependency(s, url: File.join(__dir__, 'FluidAudioASR'), requirement: {}, products: ['FluidAudioASR'])
  end
end
