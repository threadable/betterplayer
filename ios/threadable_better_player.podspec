Pod::Spec.new do |s|
  s.name             = 'threadable_better_player'
  s.version          = '2.2.0'
  s.summary          = 'Advanced video player for Flutter.'
  s.description      = <<-DESC
Advanced video player for Flutter, forked from Better Player with Threadable-maintained updates and continued support.
                       DESC
  s.homepage         = 'https://github.com/threadable/betterplayer'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Threadable' => 'padraig@threadable.io' }
  s.source           = { :path => '.' }
  # This podspec remains as Flutter's iOS plugin shim. The native
  # implementation is vendored into ios/threadable_better_player as a
  # self-contained Swift package.
  s.source_files = 'threadable_better_player/Sources/**/*'
  s.public_header_files = 'threadable_better_player/Sources/**/*.h'

  s.dependency 'Flutter'

  s.platform = :ios, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
