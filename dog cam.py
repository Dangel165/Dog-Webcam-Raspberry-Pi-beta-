# =========================================================
# [1] Library Bug Fix (Monkey Patch for aiortc)
# =========================================================
import aiortc.rtcpeerconnection
from aiortc.sdp import DIRECTIONS

def fixed_and_direction(a, b):
    if a is None: a = "inactive"
    if b is None: b = "inactive"
    return DIRECTIONS[DIRECTIONS.index(a) & DIRECTIONS.index(b)]

# Force patch the library bug
aiortc.rtcpeerconnection.and_direction = fixed_and_direction
# =========================================================

import asyncio
import os
import subprocess
import time
import psutil
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.media import MediaPlayer, MediaRecorder
from threading import Thread
import weakref
import traceback

app = Flask(__name__)
CORS(app)

# =========================================================
# [2] Basic Configuration (Anonymized for GitHub)
# =========================================================
API_KEY = "YOUR_SECRET_API_KEY"
# Recording Directory (Adjust path for your environment)
RECORD_DIR = os.path.expanduser("~/Desktop/recordings")

if not os.path.exists(RECORD_DIR): 
    os.makedirs(RECORD_DIR, mode=0o777, exist_ok=True)

# System Status Container
status = {
    "camera": False, "mic": True, "speaker": True, "ir_mode": False,
    "viewer_count": 0, "is_recording": False, "cpu_temp": 0.0,
    "ram_usage": 0.0, "disk_usage": 0.0
}

# Tracking active WebRTC connections
active_connections = []

# =========================================================
# [3] System Monitoring (Hardware Stats)
# =========================================================
def update_system_stats():
    """Updates CPU temp, RAM, and Disk usage every 3 seconds"""
    while True:
        try:
            # CPU Temperature (Specific to Raspberry Pi)
            if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
                with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                    status["cpu_temp"] = round(int(f.read()) / 1000, 1)
            
            status["ram_usage"] = psutil.virtual_memory().percent
            status["disk_usage"] = psutil.disk_usage('/').percent
        except Exception as e: 
            print(f"Monitoring error: {e}")
        time.sleep(3)

# Start monitoring thread
Thread(target=update_system_stats, daemon=True).start()

# =========================================================
# [4] Camera & Connection Management
# =========================================================
def stop_rpicam():
    """Terminate all rpicam-vid processes"""
    try:
        subprocess.run(['pkill', '-9', 'rpicam-vid'], stderr=subprocess.DEVNULL)
        time.sleep(0.3)
    except: 
        pass

def cleanup_all_connections():
    """Clean up all active WebRTC peer connections"""
    global active_connections
    print(f"🧹 Cleaning up {len(active_connections)} active connections...")
    
    for conn_data in active_connections[:]:
        try:
            pc = conn_data.get('pc')
            if pc:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                loop.run_until_complete(cleanup_connection(conn_data))
                loop.close()
        except Exception as e:
            print(f"⚠️ Error during global cleanup: {e}")
    
    active_connections.clear()
    print("✅ All connections cleaned")

async def cleanup_connection(conn_data):
    """Cleanup individual media players and peer connections"""
    try:
        if 'video_player' in conn_data and conn_data['video_player']:
            try:
                if hasattr(conn_data['video_player'], 'video'):
                    conn_data['video_player'].video.stop()
            except: pass
        
        if 'audio_in_player' in conn_data and conn_data['audio_in_player']:
            try:
                if hasattr(conn_data['audio_in_player'], 'audio'):
                    conn_data['audio_in_player'].audio.stop()
            except: pass
        
        if 'audio_recorder' in conn_data and conn_data['audio_recorder']:
            try:
                await conn_data['audio_recorder'].stop()
            except: pass
        
        pc = conn_data.get('pc')
        if pc:
            try: await pc.close()
            except: pass
    except Exception as e:
        print(f"⚠️ cleanup_connection error: {e}")

# =========================================================
# [5] API Endpoints
# =========================================================
@app.route('/status', methods=['GET'])
def get_status():
    """Return current hardware and feature status"""
    if request.headers.get('X-API-Key') != API_KEY: 
        return jsonify({"error": "Unauthorized"}), 401
    return jsonify(status)

@app.route('/toggle/<feature>', methods=['POST'])
def toggle_feature(feature):
    """Toggle camera, mic, recording, etc."""
    if request.headers.get('X-API-Key') != API_KEY: 
        return jsonify({"error": "Unauthorized"}), 401
    
    status[feature] = not status[feature]
    
    # Handle Camera-off event
    if feature == "camera" and not status["camera"]:
        stop_rpicam()
        cleanup_all_connections()
    
    return jsonify(status)

@app.route('/list-records', methods=['GET'])
def list_records():
    """List all mp4 files in the recording directory"""
    files = sorted([f for f in os.listdir(RECORD_DIR) if f.endswith('.mp4')], reverse=True)
    return jsonify({"files": files})

@app.route('/video/<filename>', methods=['GET'])
def get_video(filename):
    """Serve specific video file for playback"""
    return send_from_directory(RECORD_DIR, filename)

# =========================================================
# [6] WebRTC Signaling Logic
# =========================================================
@app.route('/offer', methods=['POST'])
def flask_offer_handler():
    """HTTP endpoint to receive WebRTC Offer"""
    params = request.json
    print("\n🔔 New WebRTC connection request")
    
    loop = asyncio.new_event_loop()
    
    def run_in_thread():
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(handle_webrtc_offer(params))
            return result
        except Exception as e:
            print(f"❌ WebRTC processing error: {e}")
            traceback.print_exc()
            return None
        finally:
            try:
                pending = asyncio.all_tasks(loop)
                for task in pending: task.cancel()
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
                loop.close()
            except: pass
    
    try:
        answer = run_in_thread()
        if answer: return jsonify(answer)
        else: return jsonify({"error": "WebRTC Handshake Failed"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500

async def handle_webrtc_offer(params):
    """Handles SDP negotiation and media track attachment"""
    conn_data = {'pc': None, 'video_player': None, 'audio_in_player': None, 'audio_recorder': None}
    
    try:
        offer = RTCSessionDescription(sdp=params["sdp"], type=params["type"])
        pc = RTCPeerConnection()
        conn_data['pc'] = pc
        active_connections.append(conn_data)
        
        # Explicit Transceiver Setup
        video_transceiver = pc.addTransceiver("video", direction="sendonly")
        audio_transceiver = pc.addTransceiver("audio", direction="sendrecv")
        
        await pc.setRemoteDescription(offer)
        
        # --- [Video Stream] Handle Raspberry Pi Camera ---
        if status["camera"]:
            stop_rpicam()
            await asyncio.sleep(0.5)
            
            cam_cmd = [
                "rpicam-vid", "-t", "0",
                "--width", "640", "--height", "480",
                "--codec", "h264", "--inline",
                "--framerate", "20", "--profile", "baseline",
                "--level", "3.1", "--nopreview", "-o", "-"
            ]
            
            proc = subprocess.Popen(cam_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            video_player = MediaPlayer(proc.stdout, format="h264", options={"fflags": "nobuffer", "flags": "low_delay"})
            conn_data['video_player'] = video_player
            if video_player.video: pc.addTrack(video_player.video)

        # --- [Audio Stream] Handle Microphone Input ---
        if status["mic"]:
            devices = ["hw:3,0", "hw:2,0", "hw:1,0", "hw:0,0", "default"]
            for device in devices:
                try:
                    audio_in_player = MediaPlayer(device, format="alsa", options={"channels": "1", "sample_rate": "16000"})
                    if audio_in_player.audio:
                        pc.addTrack(audio_in_player.audio)
                        conn_data['audio_in_player'] = audio_in_player
                        break
                except: continue
        
        # --- [Audio Output] Remote audio to Speaker ---
        @pc.on("track")
        async def on_track(track):
            if track.kind == "audio" and status["speaker"]:
                devices = ["hw:2,0", "hw:1,0", "hw:0,0", "default"]
                for device in devices:
                    try:
                        audio_recorder = MediaRecorder(device, format="alsa", options={"channels": "1", "sample_rate": "16000"})
                        audio_recorder.addTrack(track)
                        await audio_recorder.start()
                        conn_data['audio_recorder'] = audio_recorder
                        break
                    except: continue

        # --- ICE Connection Monitoring ---
        @pc.on("iceconnectionstatechange")
        async def on_ice_change():
            if pc.iceConnectionState in ["failed", "disconnected"]:
                await cleanup_connection(conn_data)
                if conn_data in active_connections: active_connections.remove(conn_data)

        # Generate SDP Answer
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        
        return {"sdp": pc.localDescription.sdp, "type": pc.localDescription.type}
        
    except Exception as e:
        await cleanup_connection(conn_data)
        if conn_data in active_connections: active_connections.remove(conn_data)
        raise

# =========================================================
# [7] Server Execution
# =========================================================
if __name__ == '__main__':
    print("=" * 60)
    print("🐾 PET MONITOR SERVER [Production Version]")
    print("=" * 60)
    
    try:
        # Run Flask server
        app.run(host='0.0.0.0', port=5010, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        print("\n🛑 Server shutting down...")
        cleanup_all_connections()
        stop_rpicam()
        print("✅ Safe shutdown complete")