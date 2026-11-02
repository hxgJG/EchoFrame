Pod::Spec.new do |s|
  s.name = 'Sparkle'
  s.version = '2.10.1'
  s.summary = 'Sparkle official macOS update framework'
  s.homepage = 'https://sparkle-project.org'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Sparkle Project'
  s.source = {
    :http => 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz',
    :sha256 => '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
  }
  s.osx.deployment_target = '13.0'
  s.vendored_frameworks = 'Sparkle.framework'
end
