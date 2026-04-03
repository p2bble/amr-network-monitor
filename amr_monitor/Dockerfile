# =============================================================
# Stage 1: Flutter Web 빌드
# =============================================================
FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# 의존성 캐시 레이어 분리 (pubspec 변경 시에만 재다운로드)
COPY pubspec.yaml pubspec.lock* ./
RUN flutter pub get

# 소스 복사 및 웹 빌드
COPY . .
RUN flutter build web --release

# =============================================================
# Stage 2: nginx 로 정적 파일 서빙
# =============================================================
FROM nginx:1.27-alpine

COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
