# HOOPICS 로드맵: 자체 AI 엔진으로 전환

마지막 업데이트: 2026-10-24 (2단계 평가)

HOOPICS 0.1.x는 Real-ESRGAN의 AI 모델과 그 실행 엔진(realesrgan-ncnn-vulkan, 텐센트 ncnn 기반)을 내려받아
썼습니다. 이 엔진이 HOO 도구 원칙에 맞지 않아서, 0.2.0부터 우리 엔진과 NERVE 모델로 바꾸고, 그다음 우리 모델로 바꿉니다.

**HOO 도구 원칙**

- 중국 조직(회사, 연구소, 대학)이 만든 모델과 실행 엔진은 쓰지 않습니다. 사람이 아니라 조직을 기준으로 판단합니다.
- 코드, 모델(가중치), 학습 데이터가 모두 상업적으로 안전해야 합니다.
- 비개발자가 아무것도 설치하지 않고 쓸 수 있어야 합니다.

## 결정 사항

| 날짜 | 결정 |
|---|---|
| 2026-10-18 | 단계적으로 직접 개발한다: 실행 엔진 → 사진 모델 → 애니 모델 |
| 2026-10-18 | 새 엔진이 나올 때까지는 지금 버전(Real-ESRGAN)을 계속 쓴다 |
| 2026-10-18 | 조사에서 찾은 버그 3개를 바로 고친다 → v0.1.1 |
| 2026-10-24 | 앱에서 엔진을 고르게 하지 않고, 이전 버전은 GitHub Releases로 받게 한다 (아래 버전 전략) |
| 2026-10-24 | 엔진을 exe로 만들지 않고 Windows의 PowerShell 안에서 실행한다 (1단계 참고) |
| 2026-10-24 | v0.1.1에도 있는 시작 문제 2개를 v0.1.2로 고친다 (아래 0단계) |
| 2026-10-24 | VC++ 런타임은 작성자 본인의 Visual Studio Community 라이선스를 근거로 엔진 런타임에 넣어 배포한다 (1단계 참고) |
| 2026-10-24 | 테스트와 모델 평가는 작성자의 노트북 한 대에서 할 수 있는 것으로 끝낸다. 다른 PC, 다른 사람의 평가, 저자 서면 확인은 하지 않는다 |
| 2026-10-24 | v0.2.0의 모델: 사진은 NERVE 4x OTF GAN, 애니·일러스트는 NERVE 4x OTF fidelity. 애니·일러스트 품질이 0.1.x보다 떨어져도 낸다(0.1.x는 Releases에 남음). waifu2x는 쓰지 않는다 (2단계) |

### 버전 전략

- 앱 안에서 엔진을 고르게 하지 않습니다. 버전 선택은 브랜치가 아니라 GitHub Releases로 합니다.
- **v0.1.1**: Real-ESRGAN을 쓰는 마지막 기능 버전입니다. 태그를 달고 릴리스 ZIP으로 계속 받을 수 있게 둡니다.
  이후에는 심각한 문제만 고칩니다(v0.1.2).
- 새 엔진은 `hoo-engine` 브랜치에서 만들고, 품질 비교를 통과하면 `main`에 합칩니다.
- **v0.2.0**: 우리 엔진입니다. Real-ESRGAN과 ncnn을 완전히 뺍니다.
- 개발하는 동안 Real-ESRGAN은 품질 비교의 기준으로만 쓰고, 새 버전에는 넣지 않습니다.

## 작업 목록

### 0단계: v0.1.x 버그 수정

- [x] GPU 오류(`vkQueueSubmit failed` 등)가 나도 엔진이 정상 종료하고 검은 이미지를 남기는 문제 → 오류로 처리(`Err_Gpu`)
- [x] 쓰지도 않고 재배포도 금지된 마이크로소프트 디버그 DLL `vcomp140d.dll`을 풀지 않음
- [x] 문서 정정: 모델 가중치에는 라이선스가 밝혀져 있지 않음, glslang·dirent 고지 추가, ncnn 고지를 실제 빌드된 버전의 문구로
- [x] v0.1.1 태그와 GitHub Release
- [x] v0.1.2: 영어 Windows에서 사용자 이름이 한글이면 HOOPICS가 시작하지 못하는 문제 수정. 임시 폴더 이름이 ANSI 코드
  페이지 밖이면 Add-Type(csc.exe)이 실패하므로, ProgramData 바로 아래의 개인 폴더(이 사용자, SYSTEM, Administrators만 열 수
  있음)를 임시 폴더로 씁니다. 다른 사용자가 먼저 만들어 둔 폴더는 쓰지 않습니다. 작업 폴더도 개인 폴더로 만듭니다.
- [x] v0.1.2: README에 스마트 앱 컨트롤이 `start.bat`을 막을 때의 안내("ZIP을 풀기 전에 속성 → 차단 해제")

### 1단계: 우리 실행 엔진

목표: 텐센트 ncnn과 2022년 이후 관리되지 않는 서명 없는 exe를 빼고, 마이크로소프트 ONNX Runtime + DirectML로
바꿉니다. `hoo-engine` 브랜치에서 진행합니다.

**설계를 바꾼 점 (2026-10-24)**: 계획했던 `hoopics-engine.exe` 대신, 엔진 코드(C#)를 Windows에 들어 있는
`powershell.exe` 안에서 컴파일해 실행합니다(`app/engine/hoopics-engine.ps1` + `HoopicsEngine.cs`).
- Smart App Control이 켜진 PC는 서명 없는 exe를 막습니다. PC에서 직접 컴파일한 exe는 빌드할 때마다 해시가 달라서 평판이 쌓일 수 없고,
  미리 빌드해 배포해도 평판이 생길 때까지는 막힙니다.
- 지금 방식에서 디스크에 있는 실행 파일은 모두 마이크로소프트 서명 파일(powershell.exe, csc.exe, ONNX Runtime, DirectML, VC++ 런타임)뿐입니다.
  우리 코드는 소스 그대로 배포되고, Add-Type이 컴파일해서 메모리에서 불러옵니다. 화면 쪽(`Native.cs`)이 이미 쓰는 방식이라 새로 막힐 이유가 생기지 않습니다.
- 엔진은 별도 프로세스로 띄워 두고, 한 번에 여러 장과 2단계 처리를 맡깁니다. 그래서 시작과 모델 준비는 한 번만 합니다.
  작업은 명령줄이 아니라 표준 입력(UTF-8)으로 받아서, 한글 경로도 그대로 넘어가고 보안 제품의 명령줄 검사에도 걸리지 않습니다.

- [x] 엔진: 타일 처리, 이미지 읽기·쓰기(WIC), 투명도(기존 엔진과 같은 bicubic), 진행률, 오류 코드
- [x] 타일: 256px 조각에 여백 16px(애니), 24px(사진·선명 애니). 한 번에 처리한 결과와 비교하면 기존 엔진보다 정확함(아래 표)
- [x] GPU 선택: Windows가 알려 주는 외장 GPU 여부와 고성능 순서를 따름. DXGI 번호 순서는 같은 노트북에서도 부팅마다 바뀜
- [x] 정밀도: 처음 한 번 fp32와 fp16을 둘 다 재서, 결과가 같으면 빠른 쪽을 GPU·드라이버·모델별로 기억. 이 노트북에서 GTX는 fp32, Iris Xe는 fp16을 골랐음
- [x] 고장 대비: GPU가 사라지거나(DEVICE_REMOVED 등) 검은 타일을 내면 그 그림을 CPU로 마저 처리하고, 그 엔진 프로세스에서는 GPU를 다시 쓰지 않음(TDR이 반복되면 블루스크린 위험). 메모리가 모자라면 타일을 절반으로 줄여 한 번 더 시도
- [x] 결과 검증: 타일마다 줄여서 입력과 비교. 어긋나면 같은 타일을 CPU로 계산해서 GPU가 맞는지 판단
- [x] 느린 GPU: DirectML은 Windows의 GPU 시간 제한을 끄므로, 타일이 두 번 4초를 넘으면 다음 그림부터 타일을 줄여 화면이 오래 멈추지 않게 함
- [x] 사용 통계 끄기(`DisableTelemetryEvents`). 단, ONNX Runtime은 시작할 때 이미 이벤트 하나를 Windows 진단 데이터로 보냄(Windows 설정에 따라 전송)
- [x] 런타임 꾸러미(약 16MB): ONNX Runtime 1.24.4, DirectML 1.15.4, .NET용 DLL 5개, VC++ 런타임 14.44 4개. 모두 마이크로소프트 원본에서 해시를 고정해 받고,
  서명을 확인해 `dev/runtime/Build-Runtime.ps1`이 만듦. 같은 입력이면 같은 ZIP이 나옴. 앱은 ZIP과 DLL 11개의 SHA-256을 모두 확인
- [x] 배포처: 우리 GitHub Release(`runtime-ort1.24.4-dml1.15.4-r1`), 태그를 올리면 CI가 만들어 올림
- [x] 동등성 테스트: Real-ESRGAN 모델을 ONNX로 바꿔(`dev/parity/ncnn_to_onnx.py`) 두 엔진을 비교. 작은 그림은 기존 엔진과 픽셀까지 같음(개발용, 배포하지 않음)
- [x] 테스트: 직접 만든 832바이트 테스트 모델로 CI(GPU 없음)에서도 실제 엔진을 CPU로 돌림. 타일 결과 = 통짜 결과, 고장 3종 대체, 한글 경로, 상주 엔진
테스트는 작성자의 노트북 한 대에서만 합니다(2026-10-24 결정). 여기서 할 수 없는 테스트는 하지 않고, 엔진의 안전장치에 맡깁니다.

- [x] VC++ 런타임이 없는 PC 대신: 엔진이 불러오는 DLL 121개를 모두 확인. 이 노트북의 System32에는 더 새 VC++ 14.50, 내장
  DirectML 1.15.6, 내장 ONNX Runtime 1.17이 있지만, VC++ 4개와 onnxruntime, DirectML은 모두 우리 폴더의 것(14.44, 1.24.4,
  1.15.4)을 씀. 나머지는 Windows 기본 구성 요소(d3d12, dxgi, ucrtbase 등)와 Windows 보안(Defender)뿐이라, VC++가 없는 PC에서도
  같은 파일로 동작함
- [x] Smart App Control 정책 확인: 이 노트북에 있는 정책 파일을 풀어 봄. SAC 정책(`VerifiedAndReputableDesktop`)에는
  `Disabled:Script Enforcement`가 있어서, SAC는 PowerShell 스크립트를 제한 모드로 바꾸지 않음(평가 모드 정책은 같은 옵션에 감사
  모드만 더해져 있어 해석이 맞음을 확인). 엔진이 불러오는 DLL은 모두 마이크로소프트 서명. 남는 문제는 "인터넷에서 받음" 표시가 있는
  `start.bat`이 막히는 것뿐이고, README의 차단 해제 안내로 피함
- [x] 제한 모드(ConstrainedLanguage)에서는 창을 만드는 첫 줄부터 막혀 아무것도 뜨지 않음을 확인. 회사·학교 PC의 App Control이나
  AppLocker 정책이 이렇게 만들 수 있으므로, 이때는 메모장으로 안내함(`app/restricted.txt`)
- [ ] (선택) SAC를 실제로 켜고 테스트: 이 노트북은 SAC를 다시 켤 수 있는 빌드(26300)지만, 진단 데이터가 "필수"로만 되어 있어
  "선택적 진단 데이터"를 먼저 켜야 할 수 있음. 작성자가 원할 때만
- 이 노트북으로는 할 수 없어서 하지 않는 테스트: Windows 10, AMD GPU, 오래된 Intel GPU, Arm 기반 Windows. 대신 엔진은 처음에
  fp16과 fp32를 재서 고르고, 타일마다 결과를 검사하고, GPU가 실패하면 CPU로 넘어감. Arm 기반 Windows는 지원하지 않고 안내
  메시지만 띄움

이 노트북에서 잰 값 (1178×661 사진 → 4712×2644, 프로그램 시작 포함, fp16·fp32 측정이 끝난 뒤):

| | 기존 엔진 (ncnn) | 새 엔진 |
|---|---|---|
| 애니 모델, GTX 1650 Ti | 3.6초 | 4.0초 (엔진이 이미 떠 있으면 2.2초) |
| 선명한 애니 모델, GTX 1650 Ti | 6.3초 | 9.0초 |
| 사진 모델, GTX 1650 Ti | 14.6초 | 22.2초 |
| 애니 모델, Iris Xe | - | fp16 자동 선택 (타일당 98 ms, fp32는 146 ms) |
| 애니 모델, CPU만 | 불가 | 11초 |

큰 모델(사진, 선명한 애니)은 이 GTX에서 기존 엔진보다 1.4~1.5배 느립니다. 기존 엔진은 이 GPU에서 fp16으로 계산하는데,
DirectML의 fp16은 이 GPU에서 오히려 느려서 fp32를 씁니다. 우리 모델(2·3단계)은 작은 구조를 목표로 하므로 이 차이는 그때 다시 잽니다.

큰 타일 주의: 사진 모델을 384px·512px 타일로 돌리면 GTX가 오류 없이 틀린 값을 냈습니다(4배로 키운 해상도에서 64채널 중간 데이터가
1GB를 넘음). 엔진의 타일 검사가 이를 잡아 타일을 줄여 다시 하므로 결과는 맞지만, 기본 타일은 256px로 둡니다.

한 번에 처리한 결과를 기준으로 본 타일 처리 오차(가장자리 64px 제외, 높을수록 정확):

| 모델 | 기존 엔진 | 새 엔진 |
|---|---|---|
| 애니 | 54.0 dB, 최대 6 | 89.4 dB, 최대 1 |
| 사진 (여백 24px) | 41.4 dB, 최대 66 | 54.6 dB, 최대 24 |

남은 위험과 메모:
- DirectML은 유지보수 모드이고 ONNX Runtime의 DirectML 패키지는 1.24.4에서 멈췄습니다. 1.25 이후의 DirectML 관련 수정은 받을 수 없으니,
  엔진은 우리가 검증한 모델만 엽니다(사용자가 넣은 ONNX 파일은 열지 않음).
- 대안: Windows ML 패키지(Microsoft.Windows.AI.MachineLearning 2.4.89)의 onnxruntime.dll(ORT 1.27.1)은 VC++ 런타임을 안에 품고 있어서 DLL 4개가 필요 없습니다.
  다만 .NET Framework에서 쓰는 방법은 공식 지원이 아니고, 라이선스에 사용 조건 전달과 면책 조항이 있습니다. v0.2.0 전에 다시 검토합니다.
- VC++ 런타임 재배포 근거는 작성자 본인의 Visual Studio Community 라이선스(재배포 가능 코드 조항)입니다. 작성자가 2026-10-24에
  이대로 가기로 정했습니다. 법률 자문은 아닙니다.
- DirectML 라이선스는 "앱의 일부로" 배포를 허용하고 단독 배포를 금지합니다. 런타임 ZIP은 HOOPICS만 내려받는 구성 요소로 두고 고지문을 함께 넣었습니다.
  더 보수적으로 가려면 DirectML.dll만 nuget.org에서 직접 받는 방법(필요한 부분만 범위 요청, 약 9.3MB)이 있습니다.

### 2단계: 중국 것이 아닌 모델 고르기

평가는 이 노트북에서 할 수 있는 것으로 끝냅니다(2026-10-24 결정). 다른 사람의 블라인드 비교와 저자의 서면 확인은 하지 않고,
공개된 라이선스 표기와 아래 측정으로 판단합니다.

| 후보 | 용도 | 만든 곳 | 라이선스 | 결과 |
|---|---|---|---|---|
| [NERVE](https://huggingface.co/Phips/NERVE) | 사진·일반 | Philip Hofmann (스위스, 개인) | 코드·가중치 Apache-2.0. 학습 데이터는 PxHere 사진(CC0 표기) | 사진 모델 후보. 그림에서는 지금 모델보다 흐리거나 잡티가 생김 |
| [waifu2x / nunif](https://github.com/nagadomi/nunif) | 애니·일러스트 | nagadomi (일본, 개인) | 저장소 MIT, 가중치 라이선스는 따로 밝히지 않음. 학습 데이터는 2012년 크롤링 | 학습 데이터가 원칙에 맞지 않아 제외. 수치로는 가장 좋지만 눈으로는 지금 모델보다 흐림 |

- [x] 실행: NERVE 체크포인트(.safetensors)를 torch 없이 직접 읽어 ONNX로 바꿈(`dev/models/nerve_to_onnx.py`).
  저자가 공개한 ONNX와 결과가 같음(최대 1/255 차이). bicubic 부분을 고정 합성곱으로 바꿔서, DirectML에 bicubic Resize가 없어
  그 노드만 CPU로 넘기는 공개 ONNX보다 빠름. NERVE 학습에는 traiNNer-redux(BasicSR 계열 학습 코드)와 Real-ESRGAN 방식의 열화
  합성을 썼지만, 모델 구조와 가중치는 저자 본인 것
- [x] waifu2x 공개 ONNX는 DirectML에서 결과가 틀림(GTX·Iris 모두, CPU와 4~6 dB). 원인: PyTorch가 자르기(`F.pad`에 음수)를
  음수 Pad로 내보내는데 DirectML이 이를 잘못 계산함. Slice로 바꾸면 CPU와 같아짐(107~128 dB). 입력 크기는 4의 배수여야 함
- [x] 속도 (1178×661 → 4712×2644, 프로그램 시작 포함, fp16·fp32 측정 뒤):

  | | GTX 1650 Ti | Iris Xe | CPU만 |
  |---|---|---|---|
  | Real-ESRGAN 사진 모델 (지금) | 22.8초 | - | - |
  | NERVE 4x | 4.4초 (fp32) | 7.2초 (fp16) | 20~27초 |
  | waifu2x swin_unet 4x | 12~56초 (큰 타일이 가끔 틀려 다시 계산) | 27초 (fp32) | - |
  | waifu2x cunet 2x (2배만) | 2.4초 | - | - |

- [x] 원본과 비교: Kodak 사진 24장(사용 제한 없음)과 Wikimedia Commons의 CC0 아니메풍 그림 11장을 1/4로 줄이고, 그대로인 것과
  JPEG(사진 70, 그림 75)으로 손상한 것을 4배로 키워 원본과 비교(PSNR dB, 높을수록 원본에 가까움, 가장자리 8px 제외).
  GAN 모델은 선명하게 만드는 대신 이 수치가 낮게 나옵니다.

  | 모델 | 사진 | 사진 JPEG | 그림 | 그림 JPEG |
  |---|---|---|---|---|
  | bicubic | 25.93 | 24.75 | 24.66 | 23.96 |
  | Real-ESRGAN 사진 (지금) | 25.16 | 24.28 | - | - |
  | Real-ESRGAN 애니 (지금) | 25.68 | 24.83 | 27.25 | 26.61 |
  | Real-ESRGAN 선명한 애니 (지금) | - | - | 27.78 | 27.40 |
  | NERVE 4x release | 27.66 | 24.83 | 32.99 | 26.49 |
  | NERVE 4x OTF fidelity | 27.03 | 25.35 | 29.18 | 27.06 |
  | NERVE 4x OTF GAN | 26.02 | 24.38 | 29.73 | 27.33 |
  | waifu2x swin_unet 4x | - | - | 36.44 | 31.42 |
  | waifu2x cunet 2x 두 번 | - | - | 34.32 | 29.54 |

- [x] 가린 비교: 모델 이름을 가리고 잘라낸 부분을 나란히 놓아 고른 뒤 이름을 확인함. 원본이 있는 것과 실제 저화질 그림(NERVE 예제 8장,
  애니 화면 1장)을 합쳐 사진 8곳, 그림 15곳
  - 사진: 지금 사진 모델이 4.5곳, NERVE GAN이 2.5곳, waifu2x가 1곳(글자)에서 가장 좋았음. 합성 손상 사진에서는 NERVE GAN이
    비슷하거나 나았고, 실제 저화질 사진에서는 지금 모델이 나았음. 둘 다 작은 글자를 다른 모양으로 바꾸는 경우가 있었음
  - 그림: 지금 선명한 애니 모델이 12곳에서 가장 좋았음(같은 수준 포함). waifu2x는 깨끗하지만 흐림. NERVE 중에서는 OTF fidelity가
    가장 깨끗하고, release와 GAN은 JPEG 그림에 잡티가 생김
- [x] 라이선스(서면 확인 없음): NERVE 가중치는 Apache-2.0로 밝혀져 있음. 학습 데이터 LUCID CC0 v2는 PxHere 사진으로 만들었고,
  PxHere는 모든 사진을 CC0라고 밝히지만 사용자가 올린 사진이라 한 장씩 확인된 것은 아님. waifu2x 가중치는 MIT 저장소의 릴리스에
  있지만 라이선스를 따로 밝히지 않았고, 학습 데이터가 크롤링이라 원칙에 맞지 않음
- [x] 결정(2026-10-24): 사진은 NERVE 4x OTF GAN, 애니·일러스트는 NERVE 4x OTF fidelity로 v0.2.0을 냄. 애니·일러스트에서
  지금보다 흐려지는 것은 받아들이고, 0.1.x는 Releases에 남김

### 3단계: 우리 사진 모델

- [ ] 데이터: 직접 찍은 사진 1천~3천 장(0.5배로 줄여서 깨끗하게)과 CC0 자료(예: The Met Open Access). 이미지마다 출처 기록(URL, 라이선스, 날짜, SHA-256)
- [ ] 구조: 소형 합성곱 네트워크(32층, 약 120만 파라미터). 서브픽셀 업샘플링(ESPCN, Twitter)과 잔차 학습(VDSR·EDSR, 서울대)을 논문을 보고 직접 구현
- [ ] 열화 합성: BSRGAN(ETH 취리히) 방식으로 흐림, 잡음, JPEG, 축소를 섞음. Real-ESRGAN(텐센트)의 2차 열화는 아이디어만 참고하고 코드는 쓰지 않음
- [ ] 학습 코드: PyTorch로 직접 작성(BasicSR은 쓰지 않음)
- [ ] 1차 학습(L1 손실)은 이 노트북에서(가벼운 설정으로 약 19시간), 2차 학습(GAN)은 RTX 4090 임대($0.34~0.89/시간).
  GPU 임대는 "노트북 한 대에서만"(2026-10-24 결정)과 맞지 않으므로 3단계를 시작하기 전에 다시 정함
- [ ] 지각 손실(perceptual loss)용 VGG19를 쓸지 결정. 학습에만 쓰고 배포하지 않지만 ImageNet으로 학습된 모델이고 ImageNet은 비상업 조건
- [ ] ONNX로 내보내고 Real-ESRGAN 사진 모델과 블라인드 비교

### 4단계: 우리 애니·일러스트 모델 (데이터가 생기면)

- [ ] 데이터: CC0 벡터 그림(Openclipart)을 고해상도로 렌더링, CC BY 오픈 영화(Blender "Spring"), 퍼블릭 도메인 판화, 직접 그리거나 의뢰한 그림(학습과 모델 배포를 허락하는 서면 계약)
- [ ] 피할 것: 크롤링한 애니 이미지, Pepper&Carrot("AI derivation prohibited" 표시), 비상업 라이선스 모델과 데이터
- [ ] 이후 과정은 3단계와 같음

### 5단계: v0.2.0 출시

2단계 결정에 따라 v0.2.0은 NERVE 모델로 3·4단계보다 먼저 냅니다. 우리 모델이 나오면 모델 꾸러미만 새로 냅니다.

- [x] 모델 꾸러미 `hoopics-models-nerve-r1.zip`(약 20MB): `dev/models/Build-Models.ps1`이 저자의 저장소에서 커밋과 해시를
  고정한 체크포인트를 받아 fp32·fp16 ONNX로 바꿈. 같은 입력이면 같은 ZIP이 나옴(numpy 2.4와 2.5, 새로 받은 파일로 확인).
  태그 `models-*`를 올리면 CI가 만들어 올림(`.github/workflows/models.yml`). 앱은 런타임처럼 ZIP과 모델 파일 4개의 SHA-256을 확인
- [x] 앱: 그림 종류는 "애니·일러스트"(NERVE fidelity)와 "사진"(NERVE GAN) 두 가지. 처음 실행할 때 런타임과 모델을 함께 받음(약 36MB).
  이 PC 안의 웹 서버로 받기, 해시 확인, 풀기, 두 모델로 키우기까지 확인
- [x] 타일 여백 32px: 타일로 나눈 결과를 한 번에 처리한 결과와 비교(가장자리 64px 제외)

  | 여백 | 16px | 24px | 32px | 48px |
  |---|---|---|---|---|
  | 사진 (GAN) | 56.3 dB | 61.7 dB | 63.2 dB | 63.3 dB |
  | 애니 (fidelity) | 64.4 dB | 68.5 dB | 69.4 dB | 69.4 dB |

- [x] Real-ESRGAN·ncnn 관련 코드, 문서, 고지 제거(`dev/parity` 삭제, 0.1.x 고지는 v0.1.2 태그에 남김). 0.1.x 엔진 때문에 두었던
  "작업 폴더는 영문 경로만" 제한도 뺌
- [x] 새 고지: ONNX Runtime, DirectML, VC++ 런타임(그대로), NERVE(Apache-2.0 원문과 바꾼 내용)
- [x] README에 이전 버전(v0.1.x) 안내
- [x] 창 스크린샷 다시 찍기(아래쪽의 버전과 모델 이름), 데모 그림도 NERVE로 다시 만듦
- [x] 모델 카드: `docs/MODELS.md`(학습 데이터 출처, 라이선스, 변환, 평가)
- [ ] 모델 꾸러미 릴리스(`models-nerve-r1`) 게시, `main` 병합, v0.2.0 태그와 릴리스 (작성자 확인 후)

### 공통 과제 (버전과 상관없이)

1단계 조사에서 v0.1.1에도 해당하는 문제가 나왔습니다. 두 가지는 v0.1.2에서 고쳤습니다.

- [x] **Smart App Control이 켜진 PC에서 `start.bat`이 막힘**: 브라우저로 받은 ZIP을 탐색기로 풀면 모든 파일에
  "인터넷에서 받음" 표시(Mark of the Web)가 붙고, 이 표시가 있는 `.bat`은 더블클릭해도 실행되지 않습니다(허용 버튼도 없음).
  코드 서명으로도 해결되지 않습니다(.bat은 서명할 수 없음). v0.1.2부터 README와 릴리스 안내에 "ZIP을 풀기 전에 속성 → 차단 해제"를 적었습니다.
- [ ] **v0.1.x 엔진과 Smart App Control**: v0.1.x가 내려받는 `realesrgan-ncnn-vulkan.exe`에는 서명이 없어서, SAC가 켜진 PC에서는
  마이크로소프트의 평판 정보에 따라 막힐 수 있습니다. 0.2.0의 새 엔진에는 서명 없는 실행 파일이 없습니다.
- [ ] **제어된 폴더 액세스(랜섬웨어 방지)가 켜진 PC**: PowerShell은 사진·문서 폴더에 쓸 수 없습니다.
  결과를 저장하지 못하면 보호되지 않는 폴더로 저장하고 안내해야 합니다.
- [x] **영어 Windows에서 사용자 이름이 한글이면 HOOPICS가 시작하지 못함**: 임시 폴더 이름을 ANSI 코드 페이지로 쓸 수 없으면
  Add-Type(csc.exe)이 실패합니다. v0.1.2와 `hoo-engine`에서 고쳤습니다(ProgramData 바로 아래의 개인 임시 폴더 사용).

### 예상 작업량 (추정)

| 작업 | 시간 | 비용 |
|---|---|---|
| 실행 엔진 | 40~80시간 | 없음 |
| 데이터 수집과 출처 기록 | 60~150시간 | 없음(그림을 의뢰하면 별도) |
| 학습 코드 | 60~120시간 | 없음 |
| 사진 모델 학습 | 40~80시간 | $50~400 |
| 애니 모델 학습 | 40~100시간 | $50~400 + 데이터 |
| 출시 정리 | 20~40시간 | - |
| **합계** | **260~570시간 (파트타임 3~6개월)** | **약 $100~1,000** |

## 조사 결과 요약 (2026-10-18)

### 지금 엔진의 구성과 출처

| 구성요소 | 만든 곳 | 국가 | 라이선스 |
|---|---|---|---|
| Real-ESRGAN 모델 3개 | 텐센트 ARC Lab, 중국과학원 선전선진기술연구원·중국과학원대학, 상하이 AI 실험실 (중국 정부 연구비 일부 지원) | 중국 | 가중치 라이선스 명시 없음 (저장소 코드는 BSD 3-Clause) |
| realesrgan-ncnn-vulkan.exe | Real-ESRGAN 저자(당시 텐센트 ARC Lab), realsr-ncnn-vulkan 기반 | 중국 | MIT |
| ncnn | 텐센트 | 중국 | BSD 3-Clause |
| libwebp, glslang, dirent, vcomp140.dll | 구글, Khronos, Toni Ronkko, 마이크로소프트 | 미국 등 | BSD, MIT, Apache 2.0, 마이크로소프트 재배포 조건 |

모델과 실행 엔진이 둘 다 텐센트 계열이라서, 한쪽만 바꿔서는 원칙을 지킬 수 없습니다.

### 라이선스와 학습 데이터

- 코드는 모두 상업적으로 쓸 수 있습니다(고지 유지 조건).
- 모델 가중치에는 라이선스가 밝혀져 있지 않습니다. 2023년 8월부터 열려 있는 질문([#677](https://github.com/xinntao/Real-ESRGAN/issues/677))에
  저자가 답하지 않았습니다. 저작권 표시는 저자 개인 이름이지만 연구는 텐센트에 다니던 중에 했습니다.
- 사진 모델은 DIV2K("학술 연구 목적으로만"), Flickr2K(약관 없음), OST(검색엔진으로 모은 사진과 ImageNet 배경)로 학습했습니다.
- 애니 모델 2개(기본 모델 포함)는 학습 데이터를 공개하지 않았습니다.
- 그래서 상업적 사용은 허용도 금지도 아닌 회색지대입니다.

### 안전성

- 받는 zip은 공식 파일과 해시가 같고, exe는 공개 소스로 GitHub 자동 빌드가 만든 파일과 바이트 단위로 같습니다.
- exe에는 네트워크 기능이 없고, 실행을 감시해 봐도 네트워크 연결, 다른 프로그램 실행, 시작프로그램 변경이 없었습니다.
  Windows Defender 검사도 이상 없었습니다.
- 약점은 2022년 이후 관리가 끊긴 점, exe에 서명이 없는 점, 안에 든 libwebp(CVE-2023-4863)와 ncnn(CVE-2026-50144)의
  알려진 취약점입니다. HOOPICS는 사용자 원본 대신 새로 만든 PNG만 엔진에 넘기므로 지금 구조에서는 이 취약점이
  작동하지 않습니다. 엔진을 바꿀 때까지 이 방식을 유지합니다.
- Vulkan이 꼭 필요하고 CPU 대체 경로가 없습니다.

### 맞지 않는 대안

- Windows AI 초해상도: Copilot+ PC(NPU) 전용
- NVIDIA RTX Video Super Resolution, Maxine: RTX(텐서 코어) 전용
- AuraSR, Stable Diffusion x4 업스케일러: 4 GB 그래픽 메모리로는 너무 무거움
- APISR: 학술용으로만 허용
- SwinIR, Swin2SR: 라이선스는 깨끗하지만 이 노트북에는 너무 무거움
- HAT, DAT, SPAN, Real-CUGAN, DySample 등: 중국 기관에서 나온 구조

### 위험

- **품질**: 소형 사진 모델은 심하게 망가진 사진에서 Real-ESRGAN 사진 모델보다 약할 수 있습니다. 애니 품질은 데이터에 달려 있습니다.
- **데이터 라이선스**: 가장 큰 위험입니다. 유명 데이터셋(DIV2K, LSDIR, Flickr2K)은 학술용이거나 조건이 불명확하고,
  Unsplash·Pexels·Pixabay는 AI 학습용 수집을 금지합니다. 한국에는 AI 학습을 허용하는 별도 법 조항(TDM 예외)이 없습니다.
- **실행 엔진**: DirectML 업데이트 중단, 마이크로소프트 독점 DLL.
- **GPU 종류**: AMD와 오래된 Intel GPU는 아직 시험하지 않았습니다. 다른 프로그램이 GPU를 많이 쓰면 실패할 수 있습니다.
- **법**: 2026-01-22 시행된 AI 기본법의 생성형 AI 결과물 표시 의무가 업스케일러에도 해당하는지 검토가 필요합니다.

## 참고 자료

- Real-ESRGAN 논문: https://arxiv.org/abs/2107.10833
- Real-ESRGAN 학습 문서: https://github.com/xinntao/Real-ESRGAN/blob/master/docs/Training.md
- 가중치 라이선스 질문: https://github.com/xinntao/Real-ESRGAN/issues/677
- DIV2K 이용 조건: https://data.vision.ee.ethz.ch/cvl/DIV2K/
- ncnn 취약점 CVE-2026-50144: https://github.com/Tencent/ncnn/security/advisories/GHSA-jxmc-3mv6-7pwr
- libwebp 취약점 CVE-2023-4863: https://nvd.nist.gov/vuln/detail/CVE-2023-4863
- ONNX Runtime DirectML: https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html
- Windows GPU 시간 초과(TDR): https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery
- Smart App Control: https://support.microsoft.com/en-us/topic/what-is-smart-app-control-285ea03d-fa88-4d56-882e-6698afdb7003
- NERVE: https://huggingface.co/Phips/NERVE
- NERVE 학습 데이터 LUCID CC0 v2: https://huggingface.co/datasets/Phips/lucid-cc0-v2-hc-512 , PxHere 라이선스: https://pxhere.com/en/license
- waifu2x / nunif: https://github.com/nagadomi/nunif
- 평가 그림: Kodak 사진 https://r0k.us/graphics/kodak/ , Wikimedia Commons의 CC0 그림(예: https://commons.wikimedia.org/wiki/File:Anime_Girl_Cola_Mateya.svg)
- 논문: [ESPCN](https://arxiv.org/abs/1609.05158), [VDSR](https://arxiv.org/abs/1511.04587),
  [EDSR](https://arxiv.org/abs/1707.02921), [BSRGAN](https://arxiv.org/abs/2103.14006)
