platform :ios, '16.0'

# No pods. The viewfinder used to need MobileVLCKit, but VLC cannot play this
# camera — it refuses interleaved TCP (461) and live555 cannot resolve a local
# RTP address on iOS. RTSPStream speaks RTSP directly with system frameworks
# instead, so nothing here is required to build the app.
target 'YiCamera' do
  use_frameworks!
end
