#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'threadable_better_player'
  s.version          = '2.1.0'
  s.summary          = 'Advanced video player for Flutter.'
  s.description      = <<-DESC
Advanced video player for Flutter, forked from Better Player with Threadable-maintained updates and continued support.
                       DESC
  s.homepage         = 'https://github.com/threadable/betterplayer'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Threadable' => 'padraig@threadable.io' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  s.dependency 'Flutter'
  s.dependency 'Cache', '~> 6.0.0'
  s.dependency 'GCDWebServer', '~> 3.5.4'
  s.dependency 'HLSCachingReverseProxyServer', '~> 0.1.0'
  s.dependency 'PINCache', '~> 3.0.4'

  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

