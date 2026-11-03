Pod::Spec.new do |s|
  s.name = 'TeleCore'
  s.version = '1.0.0'
  s.summary = 'teleBackup iPhone core: rules, queue, Telegram, safe delete.'
  s.homepage = 'https://github.com/aakashchamola/teleBackup'
  s.license = { :type => 'Private' }
  s.author = 'aakashchamola'
  s.source = { :path => '.' }
  s.source_files = 'Sources/TeleCore/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'
  s.library = 'sqlite3'
end
