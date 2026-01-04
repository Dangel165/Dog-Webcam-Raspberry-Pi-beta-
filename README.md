# 🐾 Dog Webcam (Raspberry Pi) (Bata)

---

## 🇰🇷 한국어 (Korean)

### **프로젝트 소개**
라즈베리 파이(Raspberry Pi)와 플러터(Flutter)를 결합한 고성능 반려동물 웹캠앱 입니다.

### **개발 사유**
저희 집 강아지가 분리불안이 심해서 24시간 모니터링 가능한 반려동물 웹캠이 필요했습니다. 이를 위해 임베디드 시스템 연구를 겸하여 직접 개발하게 되었습니다.

### **주요 기능**
* **실시간 영상 스트리밍**: `rpicam-vid`와 `aiortc`를 사용하여 지연 시간을 최소화한 H.264 비디오 전송.
* **양방향 오디오**: 라즈베리 파이에 연결된 마이크와 스피커를 통해 실시간 소통 가능.
* **원격 제어**: 카메라 On/Off, 야간 IR 모드, 마이크/스피커 활성화 제어.
* **녹화 기능**: 원격 영상 녹화 및 서버 저장 영상 목록 확인(갤러리).
* **상태 모니터링**: CPU 온도, RAM 사용량, 디스크 잔량 실시간 확인.

### **설치 방법**
* **서버**: 라즈베리 파이에서 `pip install flask flask-cors aiortc psutil` 설치 후 `python main.py` 실행.
* **앱**: `main.dart`의 `tailscaleIp`와 `apiKey`를 수정 후 `flutter run` 실행.

---

## 🇺🇸 English (English)

### **Project Overview**
A high-performance pet monitoring webcam solution integrated with Raspberry Pi and Flutter.

### **Development Background**
My dog suffers from severe separation anxiety, which led me to build a dedicated 24/7 monitoring system. This project was developed both to care for my pet and to conduct hands-on research into embedded systems.

### **Key Features**
* **Real-time Video Streaming**: Low-latency H.264 video transmission using `rpicam-vid` and `aiortc`.
* **Two-way Audio**: Real-time voice communication via an attached microphone and speaker on the Raspberry Pi.
* **Remote Control**: Toggle Camera On/Off, Night IR mode, and Microphone/Speaker activation via the app.
* **Recording**: Remote video recording and access to the recorded file history (Gallery).
* **Status Monitoring**: Real-time system diagnostics including CPU temperature, RAM usage, and Disk space.

### **Installation**
* **Server**: Raspberry Pi(4B), run `pip install flask flask-cors aiortc psutil` then execute `python main.py`.
* **App**: Update `tailscaleIp` and `apiKey` in `main.dart` with your server info, then run `flutter run`.

---

## 🛠 Tech Stack (사용된 기술)

| Category | Technology |
| :--- | :--- |
| **Server** | Python, Flask, aiortc, PyAV |
| **Client** | Flutter, flutter_webrtc, HTTP |
| **Hardware** | Raspberry Pi 4B(8GB), Raspberry Pi Camera Module 3 NoIR , USB Mic/Speaker |


---

## ⚠️ 버그 (Known Issues)

### 🇰🇷 한국어
* **카메라 인식 오류**: 간혹 앱 실행 시 카메라 스트리밍이 즉시 시작되지 않는 버그가 있습니다 그래서 현재 WebRTC 문제를 해결 중입니다.

### 🇺🇸 English
* **Camera Recognition Issue**: There is an intermittent bug where the camera stream fails to start immediately when the app is launched. I am currently working on resolving this WebRTC-related issue to improve connection stability.
