# HOOPICS 로드맵: 자체 AI 엔진으로 전환

마지막 업데이트: 2026-10-24

HOOPICS는 지금 Real-ESRGAN의 AI 모델과 그 실행 엔진(realesrgan-ncnn-vulkan, 텐센트 ncnn 기반)을 내려받아
씁니다. 이 엔진이 HOO 도구 원칙에 맞지 않아서, 단계적으로 우리 엔진과 우리 모델로 바꿉니다.

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
| 2026-10-24 | v0.1.1에도 있는 시작 문제 2개를 v0.1.2로 고친다 (아래 0단계) |

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

### 1단계: 우리 실행 엔진 `hoopics-engine.exe`

목표: 텐센트 ncnn과 2022년 이후 관리되지 않는 서명 없는 exe를 빼고, 마이크로소프트 ONNX Runtime + DirectML로
바꿉니다. 이 노트북의 PowerShell 5.1에서 동작하는 것까지 확인했습니다.

- [ ] C# 콘솔 exe. 지금 엔진과 같은 명령줄(`-i -o -n -s 4 -m`)과 stderr 진행률(`12.50%`)을 써서 `Invoke-Engine`은 거의 그대로 둠
- [ ] 이미지 읽기·쓰기는 Windows에 들어 있는 WIC로
- [ ] 타일 처리: 256~512px 조각, 10~16px 겹침
- [ ] GPU 선택: 어댑터를 나열해서 외장 GPU 우선. 순서는 PC와 상황마다 다름(조사 중 같은 노트북에서도 다르게 나옴)
- [ ] 정밀도: GTX 16 시리즈는 FP32(FP16이 오히려 느림), Intel 내장 GPU는 FP16
- [ ] GPU 시간 초과 대비: Windows는 GPU가 2초 넘게 응답하지 않으면 드라이버를 재시작함(TDR). 작은 타일을 쓰고, `DEVICE_HUNG`이 나면 GPU로 다시 시도하지 말고 CPU로 넘어감
- [ ] CPU 대체 경로: GPU가 없거나 실패해도 느리게라도 동작
- [ ] 결과 검증: 출력이 검은 이미지가 아닌지, 다시 줄였을 때 입력과 맞는지 확인
- [ ] 세션은 모델마다 한 번만 만들고 재사용(만드는 데 0.3~9초), `Run()`은 한 번에 하나씩
- [ ] 사용 통계 끄기(`DisableTelemetryEvents`). DirectML 라이선스의 정보 수집 조항은 README 개인정보 항목에 적기
- [ ] 함께 배포할 파일: onnxruntime.dll, DirectML.dll, Microsoft.ML.OnnxRuntime.dll과 System.* 4개, VC++ 런타임 DLL 4개(MSVCP140, MSVCP140_1, VCRUNTIME140, VCRUNTIME140_1). 파일마다 SHA-256을 고정하고 마이크로소프트 서명 확인
- [ ] 엔진 배포처: 우리 GitHub Release에 올리고 해시 고정(지금은 원저자 개인 계정의 파일 하나에 의존)
- [ ] 동등성 테스트: 같은 모델을 지금 엔진과 새 엔진으로 돌려 결과 비교(개발용, 배포하지 않음)
- [ ] 깨끗한 Windows 10/11 가상 PC에서 테스트(VC++ 런타임이 없는 상태)
- [ ] exe 코드 서명 검토: 서명이 없으면 Smart App Control이 켜진 PC에서 막힐 수 있음

이 노트북에서 잰 속도(256×256 조각을 4배, 중앙값):

| 모델 크기 | GTX 1650 Ti (FP32) | Iris Xe (FP16) | CPU (i7-1165G7) |
|---|---|---|---|
| 소형, 약 62만 파라미터 (지금 애니 모델과 같은 크기) | 35~48 ms | 64~91 ms | 470~990 ms |
| 대형, 약 1,670만 파라미터 (지금 사진 모델과 같은 크기) | 820~867 ms | 1,664~1,960 ms | - |

1920×1080을 소형 모델로 4배 키우면 GTX 약 1.4초, Iris Xe 약 3초, CPU 약 20~40초로 추정합니다.

주의: DirectML은 유지보수 모드입니다(NuGet 패키지가 1.24.4에서 멈춤). 모델은 ONNX로 두어서 나중에 Windows ML
같은 다른 실행 엔진으로 바꿀 수 있게 합니다.

### 2단계: 중국 것이 아닌 모델 고르기

| 후보 | 용도 | 만든 곳 | 라이선스 | 확인할 것 |
|---|---|---|---|---|
| [NERVE](https://huggingface.co/Phips/NERVE) | 사진·일반 | Philip Hofmann (스위스, 개인) | 코드·가중치 Apache-2.0, CC0 데이터로만 학습 | DirectML 동작과 속도, 품질. 공개 1개월이고 품질 평가는 저자 본인 것뿐 |
| [waifu2x / nunif](https://github.com/nagadomi/nunif) | 애니·일러스트 | nagadomi (일본, 개인) | MIT | 공개된 ONNX가 DirectML에서 검은 화면이나 오류 → opset 17로 다시 내보내기. 학습 데이터는 2012년 크롤링(회색지대) |

- [ ] 두 후보를 1단계 엔진에서 실행하고 속도 측정
- [ ] 블라인드 비교: 같은 그림 세트를 지금 Real-ESRGAN 결과와 나란히 놓고 고르기
- [ ] 라이선스 서면 확인: nagadomi(waifu2x 가중치가 MIT인지), Philip Hofmann(출처 표기 방식)
- [ ] NERVE 학습 데이터(LUCID CC0 v2)의 CC0 표기를 믿을 수 있는지 확인
- [ ] 품질이 모자라면 v0.2.0 출시를 미룰지, 그대로 낼지 결정

### 3단계: 우리 사진 모델

- [ ] 데이터: 직접 찍은 사진 1천~3천 장(0.5배로 줄여서 깨끗하게)과 CC0 자료(예: The Met Open Access). 이미지마다 출처 기록(URL, 라이선스, 날짜, SHA-256)
- [ ] 구조: 소형 합성곱 네트워크(32층, 약 120만 파라미터). 서브픽셀 업샘플링(ESPCN, Twitter)과 잔차 학습(VDSR·EDSR, 서울대)을 논문을 보고 직접 구현
- [ ] 열화 합성: BSRGAN(ETH 취리히) 방식으로 흐림, 잡음, JPEG, 축소를 섞음. Real-ESRGAN(텐센트)의 2차 열화는 아이디어만 참고하고 코드는 쓰지 않음
- [ ] 학습 코드: PyTorch로 직접 작성(BasicSR은 쓰지 않음)
- [ ] 1차 학습(L1 손실)은 이 노트북에서(가벼운 설정으로 약 19시간), 2차 학습(GAN)은 RTX 4090 임대($0.34~0.89/시간)
- [ ] 지각 손실(perceptual loss)용 VGG19를 쓸지 결정. 학습에만 쓰고 배포하지 않지만 ImageNet으로 학습된 모델이고 ImageNet은 비상업 조건
- [ ] ONNX로 내보내고 Real-ESRGAN 사진 모델과 블라인드 비교

### 4단계: 우리 애니·일러스트 모델 (데이터가 생기면)

- [ ] 데이터: CC0 벡터 그림(Openclipart)을 고해상도로 렌더링, CC BY 오픈 영화(Blender "Spring"), 퍼블릭 도메인 판화, 직접 그리거나 의뢰한 그림(학습과 모델 배포를 허락하는 서면 계약)
- [ ] 피할 것: 크롤링한 애니 이미지, Pepper&Carrot("AI derivation prohibited" 표시), 비상업 라이선스 모델과 데이터
- [ ] 이후 과정은 3단계와 같음

### 5단계: v0.2.0 출시

- [ ] Real-ESRGAN·ncnn 관련 코드, 문서, 고지 제거
- [ ] 새 고지: ONNX Runtime(MIT)과 그 ThirdPartyNotices, DirectML 재배포 라이선스, 모델 라이선스
- [ ] README에 이전 버전(v0.1.1) 안내
- [ ] 모델 카드: 학습 데이터 출처, 라이선스, 버전

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
- waifu2x / nunif: https://github.com/nagadomi/nunif
- 논문: [ESPCN](https://arxiv.org/abs/1609.05158), [VDSR](https://arxiv.org/abs/1511.04587),
  [EDSR](https://arxiv.org/abs/1707.02921), [BSRGAN](https://arxiv.org/abs/2103.14006)
