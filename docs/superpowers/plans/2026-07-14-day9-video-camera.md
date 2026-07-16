# Day 9 Video and Camera Detection Plan

> Execute this plan in the Day 9 worktree. Keep local Windows mode free of WSL, Docker, Redis, and MinIO runtime requirements.

## 1. Establish contracts and regression tests

- Add video settings and a realtime detector seam.
- Write failing tests for realtime inference, task state, upload validation, and WebSocket message validation.
- Run the focused backend tests to prove the initial failures.

## 2. Implement backend video processing

- Add the progress registry, bounded executor, video metadata/frame sampling, cleanup, annotated frame storage, and result serialization.
- Add authenticated video submission and polling endpoints.
- Add the agent adapter and register the router.
- Run focused and full backend tests.

## 3. Implement camera streaming

- Add token-query WebSocket authentication, config validation, model warmup, response-driven frame processing, GPU/CPU settings, and cleanup.
- Add protocol and fake-detector tests.
- Run the backend suite again.

## 4. Implement React workflows

- Add detection API helpers and store video workflow.
- Add video upload/result components and camera page.
- Add navigation and Vite WebSocket proxy support.
- Add component/API tests and build the frontend.

## 5. Run integration checks and integrate locally

- Start the backend and frontend from the local environment.
- Check health, upload a sample video, poll to completion, and verify annotated key-frame URLs.
- Verify camera route and WebSocket handshake with a small protocol client or browser smoke test.
- Review the full diff, run `git diff --check`, commit the Day9 branch, merge it locally into the current feature branch, and remove only the temporary Day9 worktree and branch after verification.
