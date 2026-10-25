# AutoUpdate — 공용 업데이트 기반

공유 작업 경로: `\\H255\AI-Work\제작중인 프로그램\AutoUpdate`

AutoUpdate는 프로그램 소스의 Git 동기화와, 실행 중인 앱이 받는 업데이트를 구분한다. Git 동기화는 이 엔진의 소스 이력을 보존한다. 공용 런타임은 검증된 버전 패키지를 각 연결 앱에 전달한다. 소스가 GitHub와 동기화됐다는 사실만으로 실행 중인 앱이 패치되는 것은 아니다.

## 사용자가 확정한 자동업데이트 동작

공용 AutoUpdate와 연결된 각 프로그램은 10분마다 공유폴더의 로컬 후보와 GitHub 후보를 모두 확인하고, 시각이 아니라 버전·커밋 관계·파일 SHA-256으로 유효한 최신 패키지를 고른다. 로컬이 최신이면 GitHub와 연결 프로그램에 반영하고, GitHub가 최신이면 로컬 기준본과 연결 프로그램을 갱신한다. 변경이 서로 갈라졌으면 덮어쓰지 않는다. 수정 파일이 겹치지 않는 변경만 병합하며, 같은 파일이 바뀌었으면 두 쪽을 보존하고 해결 전 적용을 멈춘다.

패키지 적용은 잠수함 패치가 기본이다. 리소스 변경은 안전한 지점에서 현재 화면을 유지한 채 바꾸고, 실행 파일 교체처럼 불가피한 경우에만 현재 화면·설정·초안·작업 상태를 저장하고 재시작한 뒤 복원한다. 시작 상태 확인에 실패하면 직전 버전으로 되돌린다.

`sync.ps1`은 AutoUpdate 저장소의 로컬 Git 변경과 GitHub 커밋 계보를 동기화한다. 앱 작업자는 검증된 로컬 패키지가 GitHub보다 새 버전이면 초안 릴리스로 올리고 업로드 파일과 manifest를 확인한 뒤 공개한다. 반대 방향은 GitHub의 안정 릴리스 파일을 내려받아 검증·설치한다. 충돌과 실패는 기록하고 양쪽 원본을 보존한다.

## 공용 엔진 구조

- `source/AutoUpdate.Core.psm1`: Windows PowerShell 표준 구성요소만 쓰는 공용 패키지 코어.
- `contracts/`: 앱 연결부와 패키지 규약.
- `packages/`: 승인된 엔진·앱 패키지의 개발 산출물.
- `channels/stable/`, `channels/canary/`: 채널별 배포 포인터.
- `tools/autoupdate.ps1`: 설치·상태 조회·앱 등록 및 앱 연결용 JSON resolve 명령줄 진입점. `tools/restart-apply.ps1`은 예외 재시작 때 저장된 상태를 전달하고 실행 파일을 교체한 뒤, 새 앱의 복원 확인 전이면 이전 실행본으로 롤백한다. `status`는 활성 package manifest와 모든 payload 크기·SHA-256을 다시 검증한다. AutoUpdate 자체 v0.1.1402는 세 공용 런타임 파일로 자동 게시·설치됐고, 설치본 도우미의 성공·롤백 시험을 통과했다. 반복 확인은 릴리스 manifest만 조회하며 현재 버전이면 자산을 다시 받지 않는다.
- `tools/build-engine-release.ps1`: GitHub 배포에서 공유 엔진, 앱 연결 CLI, 재시작 도우미를 한 개의 불변 패키지로 묶는다. `tests/test_engine_release.ps1`은 세 파일이 모두 같은 매니페스트·해시 검증·설치 절차를 거치는지 확인한다.
- `tools/test-all.ps1`: `tests/test_*.ps1`을 각각 격리된 PowerShell 프로세스로 실행하고 실제 종료 코드를 확인한다. 모든 회귀시험과 자체 업데이트 전파 시험을 CI와 엔진 게시 전에 실행한다.
- `tools/sync.ps1`: AutoUpdate 소스 저장소를 커밋 그래프로 안전하게 동기화하는 별도 작업자. PC 내부 mutex와 공유 source-sync 파일 잠금을 함께 사용해 두 PC가 같은 공유 Git 저장소를 동시에 조작하지 않게 한다.
- `tools/update-registered-apps.ps1`: 등록된 프로그램과 AutoUpdate 자체의 공유폴더 로컬 패키지 게시 및 GitHub 릴리스 확인·적용을 10분 시작 간격으로 수행하는 공용 작업자. 각 주기 처리시간을 빼서 시작 간격 누적 지연을 막는다. 공유 outbox 잠금으로 두 PC의 패키지 게시·설치 주기가 겹치지 않게 직렬화하고, 잠금을 얻지 못한 PC는 다음 주기에 다시 확인한다. AutoUpdate 자체가 새 패키지를 받으면 같은 주기 안에서 새 코어 모듈을 다시 불러온 뒤 나머지 등록 앱을 처리한다. 작업자 스크립트 자체가 공유 폴더에서 바뀌면 다음 확인 주기 뒤 숨김으로 새 프로세스를 이어 실행한다.
- `tools/build-local-package.ps1`: `outbox/apps/<AppId>/build.json`의 payload 명세를 읽고 선언된 파일이 바뀌거나 원격보다 로컬 패키지 버전이 낮으면 새 패키지를 만든다. 버전은 로컬·GitHub 최신보다 높게 자동 증가한다.
- `tools/build-module-package.ps1`: 모듈 소스 폴더를 불변 버전 패키지로 만들고 파일별 크기와 SHA-256을 기록한다. 코드 파일은 기본적으로 `restart` 모드로 분류하며, 라이브 모듈에는 앱의 실제 재로딩 계약이 필요하다.
- `outbox/apps/<AppId>/build.json`: 앱별 1회 빌드 연결 설정. AutoUpdate 자체도 `outbox/apps/AutoUpdate/build.json`으로 `source/AutoUpdate.Core.psm1`, `tools/autoupdate.ps1`, `tools/restart-apply.ps1` 변경을 감지해 공통 엔진·앱 연결 CLI·재시작 도우미를 함께 패키징한다. 빌드 산출물은 C: 임시 폴더에서 공유폴더로 원자 이동할 수 없으므로 대상 볼륨에 임시 복사한 뒤 같은 볼륨에서 이름을 확정한다.
- `outbox/apps/<AppId>/<version>/`: 각 앱의 로컬 빌드 패키지 후보. 새 버전 폴더는 불변으로 두며 로컬 확인 시 GitHub의 최신 릴리스와 함께 비교한다. 이 경로는 공유폴더에만 두고 Git 동기화 대상에서는 제외한다.
- `tools/register-app.ps1`: 프로그램을 공용 업데이트 목록에 한 번 등록하는 연결 명령.
- `tools/install-update-task.ps1`: 사용자 로그인 후 공용 업데이트 작업자를 숨김 백그라운드에서 실행하도록 등록한다.
- `tools/install-background.ps1`: 사용자 로그인 시작 폴더에 숨김 실행 바로가기를 설치한다.
- `state/`, `logs/`: PC별 상태와 로그. 저장소에 올리지 않는다.

패키지는 앱 ID·버전·플랫폼·아키텍처·최소 엔진 버전·호환 계약과 모든 파일의 경로·종류·크기·SHA-256을 선언한다. 엔진은 각 파일을 staging에서 검증한 다음 불변 버전 폴더에 넣고 `current.json`을 원자적으로 바꾼다. 검증이나 전환이 실패하면 현재 포인터와 이전 정상 버전을 보존한다. 구버전으로의 자동 다운그레이드는 거절한다. 사용자 설정·자격증명·캐시·작업 데이터는 패키지 디렉터리 바깥에 둔다.

잠수함 패치는 기본이다. 패키지 사양에서 모드를 생략하면 데이터·리소스는 `live`로 처리하고, 실행 코드·런타임 파일처럼 같은 프로세스에서 바꾸면 안전하지 않은 파일이 있을 때만 `restart`로 처리한다. 호환성 스키마 변경 등 앱이 라이브 적용을 거절해야 할 때도 재시작 예외를 지정한다. 엔진은 UI 상태 저장·복원과 앱 안전 시점 판단을 추측하지 않는다. 앱 연결부가 팀장 기획 계약의 훅을 구현해 같은 프로세스의 live 전환 또는 현재 화면·설정·초안·작업 상태 저장 → 정상 종료 → helper 교체 → 같은 화면과 상태로 재기동 → 기동 확인 → 실패 시 이전 버전·상태 복구를 맡는다. 이 분리가 잠수함 패치 동작과 코드 교체를 안전하게 함께 지원한다.

## 연결과 인증

각 앱은 한 번만 얇은 연결부를 추가해 공용 엔진의 `Get-AuVerifiedCurrent`로 검증된 버전 경로를 읽고 앱별 훅을 제공한다. 이후 공용 엔진 업데이트는 연결된 앱들이 정해진 안전 경계에서 새 엔진 버전을 로드하게 한다. 이미 엔진이 각 실행 파일에 복사되어 있는 앱은 연결부 전환과 호환 검증을 한 번 거쳐야 한다. 연결되지 않은 앱에 공용 엔진 수정이 저절로 도달한다고 간주하지 않는다.

## 공유 모듈

반복해서 여러 프로그램이 쓰는 기능은 앱 패키지에 복사하지 않고 모듈 ID와 API 주 버전을 선언해 불러온다. 모듈 버전은 `outbox/modules/<ModuleId>/versions/<version>/`에 불변으로 게시하고, `current.json` 포인터는 검증을 끝낸 뒤 마지막에 바꾼다. 각 PC는 처음 사용할 때 모듈을 `%LOCALAPPDATA%\Siny\AutoUpdate\modules\<ModuleId>\versions\<version>`에 한 번 내려받고, 같은 PC의 프로그램들은 같은 캐시 경로를 사용한다. 다른 API 주 버전의 모듈이 게시되어도 각 앱은 요구한 API와 맞는 가장 높은 검증 버전을 고른다.

모듈을 수정해 게시하면 연결된 앱은 다음 공용 업데이트 확인 때 새 호환 버전을 내려받는다. 이미 실행 중인 코드가 자동으로 메모리에서 교체되지는 않는다. 앱 연결부가 모듈을 다시 불러올 안전 시점과 UI·작업 상태 복원을 구현해야 잠수함 패치가 실제 동작한다. 재로딩이 불가능한 코드는 모듈 manifest에서 `restart`로 처리하고 기존 상태 저장·복구 재시작 경로를 쓴다. 모든 기존 프로그램이 자동으로 모듈을 쓰게 되는 것은 아니며, 프로그램마다 의존성 선언과 활성화 연결을 한 번 적용해야 한다.

현재 모듈 게시 정책은 공유폴더 로컬 파일럿이다. GitHub 배포는 아직 연결하지 않았다. 파일 해시 검증은 손상과 같은 버전의 내용 충돌을 찾아내며, 원격 게시자 인증은 별도 배포 단계에서 추가한다. 모듈 manifest와 앱 의존성 규약은 `contracts/modules.md` 및 JSON schema에 정리했다.

등록은 `tools/register-app.ps1 -AppId <고유 ID> -Owner <GitHub 소유자> -Repository <저장소> -Architecture <any|x86|x64|arm64>`로 한 번 수행한다. 등록부는 PC의 AutoUpdate 상태 폴더에 저장되며 Git 저장소에 커밋되지 않는다. `tools/install-background.ps1`은 로그인 시작 폴더에서 소스 동기화와 등록 앱 업데이트 확인을 숨김 백그라운드로 실행한다. 앱마다 `outbox/apps/<AppId>/build.json`을 한 번 준비하면 작업자는 10분마다 명시한 payload 파일의 해시를 확인한다. 소스가 바뀌면 불변 패키지를 만들고 로컬·GitHub 최신 버전보다 patch 번호를 올린다. 소스가 그대로면 건너뛴다. 새 로컬 패키지는 초안 릴리스로 게시하고 manifest와 원격 파일의 크기·SHA-256을 확인한 뒤 공개한다. GitHub가 더 새 버전이면 내려받아 검증 후 공유 outbox와 앱 상태 경로에 저장한다. 결과는 사용자별 AutoUpdate 상태 폴더의 `logs/app-updates.jsonl`에 남으며, 각 행의 `engine_version`은 해당 검사를 실제 처리한 공용 엔진 버전을 기록한다. 릴리스 생성에는 등록 저장소의 GitHub Contents 쓰기 권한이 필요하다. 실제 실행 중 live 패치·상태 보존 재시작에는 앱 연결부가 별도로 필요하다.

프로덕션 배포는 설정된 비공개 GitHub 저장소의 release asset과 정상 HTTPS 검증을 사용한다. PAT는 `AutoUpdate/github` Windows 자격 증명 대상에서 읽어야 하며 명령행·설정·로그·패키지에 쓰지 않는다. 최소 저장소와 최소 권한만 허용한다. 로컬 `PackageRoot` 설치는 격리된 검증에만 사용한다. 소스 Git 동기화는 커밋 그래프를 기준으로 fast-forward만 적용하고, 분기 시 양쪽 이력을 보존한 채 멈춘다.

## 현재 구현 상태

- 준비됨: 10분마다 로컬/원격 커밋 계보를 확인하는 소스 동기화 작업자. 로컬 bare 저장소 시험에서 로컬 push, 원격 fast-forward, 분기 보존을 확인했다.
- 구현됨: PC별 앱 등록부, 등록된 앱의 최신 GitHub 릴리스 10분 확인/설치, 로그인 시 시작하는 숨김 백그라운드 실행. AutoUpdate 자체는 `siny-dev/auto-update`에 등록되어 있고 이 PC에는 v0.1.1402가 설치되어 있다.
- 구현됨: 불변 버전 staging, 전체 파일 크기·SHA-256 확인, 경로 탈출 방지, 앱/아키텍처/최소 엔진 확인, 라이브 코드 거절, 원자 포인터와 이전 포인터 보존, 기본 다운그레이드 거절. `Get-AuVerifiedCurrent`가 앱에 전달하기 직전 활성 포인터·manifest·모든 payload를 다시 검증한다.
- 통과: 오프라인 패키지 staging·해시·롤백 시험과 GitHub 비공개 릴리스 실다운로드·설치·반복 확인. AutoUpdate v0.1.1402가 이 PC의 상태 루트에 설치됐고, 설치 모듈 SHA-256과 payload 검증이 통과했다. app-base V1.0.010도 공용 엔진으로 등록·원격 설치·resolve 검증까지 통과했다. Restart helper는 임시 앱 실행 파일로 정상 복원 확인 및 미확인 시 원본 실행 파일 롤백 시험을 통과했다.
- 진행: `app-base`는 기존 schema 2 호환을 유지하면서 schema 1 공용 manifest도 발행하고, 숨김 CLI로 자기 앱을 등록한 뒤 공용 엔진이 검증·설치한 패키지를 기존 live/restart 상태 보존 경로로 전달한다. 실제 Windows 32비트 컴파일과 live 적용·오류 거절·실제 재시작 복원·실행 실패 롤백·중단 교체 복구 통합시험이 통과했다. AutoUpdate CLI의 `register`·`resolve`도 설치본에서 검증됐다. 기본툴에서 만든 새 앱은 이 연결부를 상속하고 실행 시 등록된다. 기존 자체 업데이터 앱은 별도 연결 변경이 필요하다.
- 완료: 각 등록 앱이 `outbox/apps/<AppId>/<version>/` 로컬 패키지 후보와 GitHub stable 릴리스를 10분마다 비교한다. 높은 버전은 로컬 또는 GitHub에서 선택하고, 같은 버전에서 payload hash가 다르면 충돌로 보류한다. 로컬 최신 패키지 선택·실제 파일 크기/SHA-256 사전 검증·설치와 후보 판정 단위시험 통과. 손상된 높은 버전 후보는 건너뛰고 다음 유효 패키지를 선택한다. 같은 버전의 설치본에서 payload가 다르면 already-current로 오인하지 않고 충돌로 보류한다.
- 로컬 검증 완료: `build.json` 레시피에서 자동 패키지를 만들고, 변경이 없으면 건너뛰며, 바뀌거나 원격이 더 높으면 로컬·GitHub 최신보다 높은 버전을 만든다. 로컬 패키지는 GitHub 초안 릴리스에 올린 뒤 manifest·asset 수·각 원격 파일의 크기와 SHA-256을 확인하고 공개한다. 원격 최신 패키지는 검증 후 공유 outbox에 원자 저장하고 설치한다. 버전 충돌은 보류하고 덮어쓰지 않는다. 자동 빌드·후보 선택·충돌·staging/rollback, 상태 파일 누락 시 기존 패키지 인식, 마지막 패키지 손실 후 재빌드 로컬시험 통과. CI/validation #24 통과. 실제 앱에는 아직 `build.json`이 없어 앱 릴리스 게시시험은 남아 있다.
- 핵심 미완료: AutoUpdate 코어의 최신 릴리스 설치 후 같은 10분 주기에서 새 엔진을 재로딩하고 이후 앱을 처리하도록 작업자와 회귀 시험을 추가했다. 현재 상태 저장소에는 `AutoUpdate`와 `BASE-001`만 등록되어 있고, `BASE-001`은 원격 패키지 설치·검증까지 완료됐다. 실행 중 앱의 실제 live/restart 적용, 다른 기존 앱의 연결, 여러 앱이 등록된 상태에서의 전체 전파 확인이 남아 있다. 따라서 공유 폴더의 기존 모든 프로그램이 이미 자동 패치되는 상태는 아니다.
- 게시 회귀 기준: GitHub 엔진 게시 작업은 공유 런타임 3개 파일과 완전한 `tools/test-all.ps1` 시험을 통과해야 한다. 테스트·문서만 바뀐 경우에는 엔진 무변경 릴리스를 만들지 않도록 게시 경로를 런타임에 한정한다.

이 작업은 공용 엔진의 자동 전파와 라이브/재시작 경계를 먼저 완성·검증한다. 기존 앱의 최초 공용 런타임 채택은 공통 연결 계약으로 처리하고, 이후 앱마다 업데이트 엔진을 다시 패치하지 않도록 한다. MA는 포함하지 않는다.

## 사용 예

`tools/autoupdate.ps1 -Command status -StateRoot <앱 데이터 경로> -AppId <앱 ID>`는 현재 연결된 패키지를 검증한다. 앱 연결부는 같은 CLI의 `-Command resolve`를 호출해 검증된 경로·버전·모드를 JSON으로 받는다. 앱은 `-Command register -AppId <앱 ID> -Owner <소유자> -Repository <저장소> -Architecture <구조>`로 자동 등록할 수 있고, 수동 등록 스크립트는 다음 형태다.

`tools/register-app.ps1 -AppId Alarm -Owner siny-dev -Repository alarm -Architecture x64`

백그라운드 10분 확인은 다음 명령으로 설정한다. 사용자 로그인 시작 폴더에 숨김 바로가기를 만들고 지금 바로 두 작업을 시작한다.

`tools/install-background.ps1`

검증된 로컬 패키지를 설치하는 명령은 다음 형태다.

`tools/autoupdate.ps1 -Command install -PackageRoot <검증용 패키지 폴더> -StateRoot <앱 데이터 경로> -AppId <앱 ID> -Architecture x64`

공유 모듈은 아래 순서로 로컬 게시·확인한다. `ModuleSourceRoot` 기본값은 `\\H255\AI-Work\제작중인 프로그램\AutoUpdate\outbox\modules`다. 각 앱은 `app.json`에 `autoupdate-app-modules-v1` 의존성 목록을 두고, 다음 확인 주기에 `resolve-modules`를 불러 검증된 PC 공용 캐시 경로를 받는다.

```powershell
.\tools\build-module-package.ps1 -ModuleId Speakly -Version 1.0.0 -ApiMajor 1 -SourceRoot <모듈-소스> -OutputRoot <새-패키지-폴더> -ActivationMode restart
.\tools\autoupdate.ps1 -Command publish-module -ModuleId Speakly -PackageRoot <새-패키지-폴더>
.\tools\autoupdate.ps1 -Command resolve-modules -AppManifestPath <앱의-app.json> -StateRoot <PC 공용 AutoUpdate 상태 경로>
```

`app-base` 템플릿에는 공용 연결부가 포함되어 있으며 앱은 실행 후 공용 상태 저장소에 자동 등록된다. 등록부는 PC별이므로 실제 전파 대상을 확인하려면 해당 PC의 `%LOCALAPPDATA%\Siny\AutoUpdate\registry\apps.json`과 `logs\app-updates.jsonl`을 확인한다. 기존 자체 업데이터 앱은 한 번 공용 연결부를 적용해야 하며, 미등록 앱은 자동으로 업데이트되지 않는다.


## 공용 확인 주기

config/update-policy.json이 연결된 앱의 공용 확인 주기입니다. 시험 중 interval_minutes를 5로 두고, 검증 완료 후 10으로 바꿉니다. 등록 앱 작업자와 소스 동기화 작업자는 매 주기 이 설정을 다시 읽습니다. 연결된 앱의 화면 내 확인 타이머도 이 파일을 읽어 같은 주기를 적용합니다. 설정이 없거나 잘못되면 안전한 기본값 10분을 사용합니다.

## Re-sleeving 로컬 패키지 적용

AutoUpdate CLI의 install-local 명령은 공유 outbox/apps/<AppId>에서 크기·SHA-256 검증을 마친 최신 로컬 패키지를 설치합니다. Re-sleeving 연결부는 이를 사용하므로 GitHub 릴리스 없이도 H255 공유 실행본을 갱신할 수 있습니다. 실행 파일 교체는 앱별 안전 적용 도구가 맡고 공용 엔진은 앱 폴더로 복사하지 않습니다.
