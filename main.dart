import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
        ),
      ),
      home: PetCamApp(),
    ));

class PetCamApp extends StatefulWidget {
  @override
  _PetCamAppState createState() => _PetCamAppState();
}

class _PetCamAppState extends State<PetCamApp> with WidgetsBindingObserver {
  // ==========================================================
  // [Part 1] Configuration & State Management
  // ==========================================================
  
  // Server Configuration (Replace with your own settings for GitHub)
  final String tailscaleIp = "YOUR_SERVER_IP"; 
  final String serverPort = "5010";
  final String apiKey = "YOUR_API_KEY";

  // System Log History
  final List<String> _logHistory = [];
  
  // Status Map: Synchronized with Python Server
  Map<String, dynamic> status = {
    "camera": false,
    "mic": false,
    "speaker": false,
    "ir_mode": false,
    "viewer_count": 0,
    "is_recording": false,
    "cpu_temp": 0.0,
    "ram_usage": 0.0,
    "disk_usage": 0.0
  };

  // State Control Variables
  int _prevViewerCount = 0;
  bool? _prevConnectionStatus;
  bool _isFirstLoad = true;
  bool _isConnecting = false;
  int _connectionFailCount = 0;
  Timer? _poller;

  // WebRTC Components
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isRendererInitialized = false;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  bool _isWebRTCConnecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSystem();
  }

  // Lifecycle: Auto-refresh when app returns to foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _addToLog("📱 App Resumed - Refreshing...");
      _refreshSystem();
    } else if (state == AppLifecycleState.paused) {
      _addToLog("📱 App Paused");
    }
  }

  @override
  void dispose() {
    _addToLog("🗑️ Disposing Resources");
    WidgetsBinding.instance.removeObserver(this);
    _poller?.cancel();
    _cleanupWebRTC();
    _remoteRenderer.dispose();
    super.dispose();
  }

  // System Logging Utility
  void _addToLog(String msg) {
    debugPrint(msg); 
    setState(() {
      _logHistory.insert(0, "${DateTime.now().toString().split('.').first.split(' ').last} | $msg");
      if (_logHistory.length > 100) _logHistory.removeLast();
    });
  }

  // Initialization: Permission Check & Status Polling
  Future<void> _initializeSystem() async {
    _addToLog("🚀 Starting System Initialization");
    try {
      final permissions = await [
        Permission.camera,
        Permission.microphone
      ].request();
      _addToLog("📋 Permission Status: $permissions");

      await _remoteRenderer.initialize();
      setState(() => _isRendererInitialized = true);

      await _fetchStatus();

      // Poll server status every 3 seconds
      _poller = Timer.periodic(
        const Duration(seconds: 3),
        (timer) => _fetchStatus()
      );
      _addToLog("✅ System Initialization Complete");
    } catch (e) {
      _addToLog("❌ Initialization Error: $e");
    }
  }

  // Logic for re-connecting WebRTC after app resume
  Future<void> _refreshSystem() async {
    _addToLog("🔄 Refreshing System Connection");
    setState(() => _isConnecting = true);
    await _cleanupWebRTC();
    await _fetchStatus();
    if (status['camera'] == true) {
      await Future.delayed(const Duration(seconds: 2));
      await _connectWebRTC();
    }
  }

  // Terminate WebRTC Session
  Future<void> _cleanupWebRTC() async {
    _addToLog("🧹 Cleaning up WebRTC");
    try {
      if (_peerConnection != null) {
        await _peerConnection!.close();
        _peerConnection = null;
      }
      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) => track.stop());
        await _localStream!.dispose();
        _localStream = null;
      }
      _remoteRenderer.srcObject = null;
      if (mounted) setState(() => _isWebRTCConnecting = false);
      _addToLog("✅ WebRTC Cleanup Finished");
    } catch (e) {
      _addToLog("⚠️ Cleanup Error: $e");
    }
  }

  // HTTP Headers with API Key
  Map<String, String> get _headers => {
    "Content-Type": "application/json",
    "X-API-Key": apiKey
  };

  // Fetch Current Server Status
  Future<void> _fetchStatus() async {
    try {
      final response = await http
          .get(Uri.parse('http://$tailscaleIp:$serverPort/status'), headers: _headers)
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        _connectionFailCount = 0;
        Map<String, dynamic> newStatus = json.decode(response.body);
        int newViewerCount = newStatus['viewer_count'] ?? 0;

        // User Notification for Connection Events
        if (!_isFirstLoad) {
          if (newViewerCount > _prevViewerCount) _showSnackBar("👥 New Viewer Joined");
        }

        // Auto-connect WebRTC if camera is enabled on server
        if (newStatus['camera'] == true && _peerConnection == null && !_isWebRTCConnecting) {
          _connectWebRTC();
        }

        setState(() {
          status = newStatus;
          _isConnecting = false;
          _prevConnectionStatus = true;
          _prevViewerCount = newViewerCount;
          _isFirstLoad = false;
        });
      }
    } catch (e) {
      _connectionFailCount++;
      if (_prevConnectionStatus != false) {
        _showSnackBar("❌ Connection Lost");
        _prevConnectionStatus = false;
        await _cleanupWebRTC();
      }
      setState(() => _isConnecting = true);
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // ==========================================================
  // [Part 2] WebRTC Signaling & Connection
  // ==========================================================
  
  Future<void> _connectWebRTC() async {
    if (_peerConnection != null || _isWebRTCConnecting) return;
    if (status['camera'] == false) return;

    setState(() => _isWebRTCConnecting = true);
    _addToLog("🔄 Initiating WebRTC Handshake...");

    try {
      // 1. Get Local Microphone Stream
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true},
        'video': false,
      });

      // 2. Create PeerConnection
      _peerConnection = await createPeerConnection({
        'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
        'sdpSemantics': 'unified-plan',
      });

      // 3. Add Local Tracks to PC
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      // 4. Handle Incoming Tracks (Remote Camera Stream)
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          setState(() {
            _remoteRenderer.srcObject = event.streams[0];
            _isWebRTCConnecting = false;
          });
        }
      };

      // 5. Create SDP Offer
      RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await _peerConnection!.setLocalDescription(offer);

      // 6. Exchange SDP with Flask Server
      final res = await http.post(
        Uri.parse('http://$tailscaleIp:$serverPort/offer'),
        headers: _headers,
        body: json.encode({"sdp": offer.sdp, "type": offer.type}),
      );

      if (res.statusCode == 200) {
        var data = json.decode(res.body);
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(data["sdp"], data["type"])
        );
        Helper.setSpeakerphoneOn(true);
        _addToLog("🎉 WebRTC Connection Established");
      }
    } catch (e) {
      _addToLog("❌ WebRTC Error: $e");
      await _cleanupWebRTC();
    }
  }

  // ==========================================================
  // [Part 3] UI Architecture & Components
  // ==========================================================
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 15),
          child: Icon(
            Icons.circle,
            color: _prevConnectionStatus == true ? Colors.greenAccent : Colors.red,
            size: 12,
          ),
        ),
        title: const Text(
          "PET MONITOR",
          style: TextStyle(letterSpacing: 1.5, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.terminal, color: Colors.blueAccent), onPressed: _showLogDialog),
          IconButton(icon: const Icon(Icons.help_outline, color: Colors.grey), onPressed: _showHelpDialog),
          IconButton(icon: const Icon(Icons.emergency, color: Colors.redAccent), onPressed: _showReportDialog),
        ],
      ),
      body: Column(
        children: [
          _buildVideoView(), // Camera Stream Area
          _buildSystemStats(), // CPU/RAM/DISK Stats
          const SizedBox(height: 10),
          _buildControlGrid(), // Function Buttons
          _buildEmergencyButton(), // Emergency Call
        ],
      ),
    );
  }

  // Camera View with Recording Overlay
  Widget _buildVideoView() {
    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          height: 230,
          decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(25)),
          clipBehavior: Clip.antiAlias,
          child: _buildVideoContent(),
        ),
        if (status['is_recording'])
          const Positioned(
            top: 30, right: 30,
            child: Row(
              children: [
                Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
                SizedBox(width: 5),
                Text("REC", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }

  // Handles different stream states
  Widget _buildVideoContent() {
    if (!_isRendererInitialized) return const Center(child: CircularProgressIndicator());
    if (status['camera'] == true && _remoteRenderer.srcObject != null) {
      return RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_off, color: Colors.grey[600], size: 40),
          const SizedBox(height: 10),
          const Text("CAMERA OFF", style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildSystemStats() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildInfo("TEMP", "${status['cpu_temp']}°C", Colors.orangeAccent),
          _buildInfo("RAM", "${status['ram_usage']}%", Colors.greenAccent),
          _buildInfo("DISK", "${status['disk_usage']}%", Colors.purpleAccent),
        ],
      ),
    );
  }

  Widget _buildInfo(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        Text(value, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildControlGrid() {
    return Expanded(
      child: GridView.count(
        crossAxisCount: 2,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        mainAxisSpacing: 15,
        crossAxisSpacing: 15,
        childAspectRatio: 1.4,
        children: [
          _buildBtn("CAMERA", Icons.videocam, 'camera'),
          _buildBtn("NIGHT IR", Icons.nights_stay, 'ir_mode'),
          _buildBtn("MIC", Icons.mic, 'mic'),
          _buildBtn("SPEAKER", Icons.volume_up, 'speaker'),
          _buildBtn("RECORD", Icons.fiber_manual_record, 'is_recording'),
          _buildGalleryBtn(),
        ],
      ),
    );
  }

  Widget _buildBtn(String label, IconData icon, String key) {
    bool isOn = status[key] == true;
    return GestureDetector(
      onTap: () => _handleButtonTap(key),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isOn ? Colors.blueAccent : Colors.transparent, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isOn ? Colors.blueAccent : Colors.white, size: 28),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(fontSize: 10, color: isOn ? Colors.blueAccent : Colors.white)),
          ],
        ),
      ),
    );
  }

  // Button Action Logic: Controls Raspberry Pi hardware via Flask API
  Future<void> _handleButtonTap(String key) async {
    _addToLog("🔘 Toggle Attempt: $key");
    try {
      final res = await http.post(
        Uri.parse('http://$tailscaleIp:$serverPort/toggle/$key'),
        headers: _headers,
      ).timeout(const Duration(seconds: 3));

      if (res.statusCode == 200) {
        await _fetchStatus();
        if (key == 'camera') {
          if (status['camera'] == true) {
            // Wait for rpicam-vid process to warm up
            await Future.delayed(const Duration(seconds: 4));
            await _connectWebRTC();
          } else {
            await _cleanupWebRTC();
          }
        }
      }
    } catch (e) {
      _addToLog("❌ Toggle Failed: $e");
    }
  }

  Widget _buildGalleryBtn() {
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (context) => GalleryPage(
          tailscaleIp: tailscaleIp, serverPort: serverPort, apiKey: apiKey
        )));
      },
      child: Container(
        decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(20)),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 28),
            SizedBox(height: 8),
            Text("GALLERY", style: TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ElevatedButton.icon(
        onPressed: _showReportDialog,
        icon: const Icon(Icons.warning),
        label: const Text("EMERGENCY REPORT"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.redAccent,
          minimumSize: const Size(double.infinity, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        ),
      ),
    );
  }

  // ==========================================================
  // [Part 4] Dialogs & Gallery Logic
  // ==========================================================

  void _showLogDialog() {
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: Colors.black87,
      title: const Text("System Logs"),
      content: SizedBox(
        width: double.maxFinite, height: 400,
        child: ListView.builder(
          itemCount: _logHistory.length,
          itemBuilder: (context, i) => Text(_logHistory[i], style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE"))],
    ));
  }

  void _showHelpDialog() {
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text("Help Guide"),
      content: const Text("1. Toggle CAMERA to start stream.\n2. Use RECORD to save clips.\n3. Check clips in GALLERY."),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
    ));
  }

  void _showReportDialog() {
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text("Emergency Call"),
      content: const Text("Would you like to call emergency services (112)?"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL")),
        TextButton(onPressed: () => launchUrl(Uri.parse("tel:112")), child: const Text("CALL", style: TextStyle(color: Colors.red))),
      ],
    ));
  }
}

// Gallery Page: Fetches recording list from the Python server
class GalleryPage extends StatefulWidget {
  final String tailscaleIp, serverPort, apiKey;
  GalleryPage({required this.tailscaleIp, required this.serverPort, required this.apiKey});

  @override
  _GalleryPageState createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List videos = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchVideos();
  }

  // Fetches file list from /list-records endpoint
  Future<void> _fetchVideos() async {
    try {
      final res = await http.get(
        Uri.parse('http://${widget.tailscaleIp}:${widget.serverPort}/list-records'),
        headers: {"X-API-Key": widget.apiKey}
      );
      if (res.statusCode == 200) {
        setState(() {
          videos = json.decode(res.body)['files'];
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Video Gallery")),
      body: isLoading 
        ? const Center(child: CircularProgressIndicator()) 
        : videos.isEmpty 
          ? const Center(child: Text("No recordings found.")) 
          : ListView.builder(
              itemCount: videos.length,
              itemBuilder: (context, i) => ListTile(
                leading: const Icon(Icons.video_library, color: Colors.blueAccent),
                title: Text(videos[i]),
                subtitle: const Text("MP4 Recording"),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
    );
  }
}