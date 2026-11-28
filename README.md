# GODSOUL 한글 패치

## 적용 대상 Steam 빌드

GODSOUL **1.99**, Steam 빌드 **`26991245`**, Windows 11. 설치기는 빌드에 해당하는 원본 파일을 확인합니다. [패치 ZIP 다운로드](https://github.com/yoodong724/GodSoul-ko/releases/download/v2026.11.28-26991245/godsoul-ko-26991245.zip)

## 마지막 릴리스 이후 업데이트 내역

1.99 게임 내 공지와 손패가 필요할 때 표시되는 스킬 안내를 번역했습니다. 2장 대사 7개를 바뀐 원문에 맞췄으며 1.98 RC1의 휴대전화 단독 스티커 기록 수정을 이어받았습니다. 시험 범위는 이번 프리릴리스 본문에 기록했습니다. [1.99 프리릴리스](https://github.com/yoodong724/GodSoul-ko/releases/tag/v2026.11.28-26991245)

## 설치 방법

1. 게임을 종료한 뒤 이전 패치는 그 버전의 `KoreanPatch/restore.cmd`로 복구합니다. 수동 설치한 `GODSOUL/Content/Paks/GodSoul-Windows_0_P.pak`은 게임 폴더 밖으로 옮깁니다.
2. `godsoul-ko-26991245.zip`을 풀고 `KoreanPatch` 폴더를 `GodSoul.exe` 옆에 둡니다.
3. `KoreanPatch/install.cmd`를 실행하고 `Y`로 확인합니다.
4. 게임 설정에서 일본어 슬롯(한국어)을 선택하고 게임을 완전히 종료한 뒤 다시 실행합니다.

제거하려면 게임을 종료하고 `KoreanPatch/restore.cmd`를 실행합니다.

## 누적 업데이트 내역

<details><summary>이전 배포 기록</summary>

- 2026-11-28 · 1.99 빌드 `26991245` 대응. 신규 공지와 스킬 안내, 2장 대사 개정.
- 2026-11-28 · 1.98 빌드 `26979880` RC1. 1.96~1.98 변경 반영과 휴대전화 단독 스티커 메시지 기록 수정. [1.98 RC1](https://github.com/yoodong724/GodSoul-ko/releases/tag/v2026.11.28-rc1)
- 2026-10-03 · 1.95 빌드 `25163435` 테스트 릴리스.

</details>

## 소스와 재현 범위

저장소에는 Windows 설치·복구 도구와 ZIP 조립 소스가 있습니다. 같은 ZIP을 조립하려면 대상 빌드의 원본 설치 파일과 릴리스 패키지의 패치 payload가 필요합니다. [Source Han Sans K 라이선스](LICENSES/SourceHanSansK-LICENSE.txt)
