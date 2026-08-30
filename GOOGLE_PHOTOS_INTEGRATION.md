# Google Photos Integration Plan

## Product decision

Use the Google Photos Picker API for user-selected memories and inspiration images. Do not request broad library access or imply that an entire private album is continuously mirrored.

This keeps the notch personal without turning it into a photo-management product. A person chooses one or a few images, Open Loops stores private local copies, and the Home view rotates or pins them later.

## Required setup

1. Create a Google Cloud project for Open Loops.
2. Enable the Google Photos Picker API.
3. Configure the OAuth consent screen and a desktop OAuth client.
4. Add the minimal `photospicker.mediaitems.readonly` scope.
5. Store the OAuth client identifier in app configuration and refresh credentials in Keychain. Never commit a client secret or token to this repository.
6. Complete Google verification before public distribution if the consent configuration requires it.

## Native flow

1. The user chooses **Google Photos** in Personalize.
2. Open Loops starts OAuth in the system browser and receives the callback through a registered URL scheme.
3. The app creates a Picker session and opens Google's picker URI.
4. The user explicitly selects images and finishes the session.
5. The app polls the session, lists only the selected media items, downloads app-owned display copies, and records local filenames in personalization state.
6. The app discards short-lived Picker session data and keeps refresh credentials in Keychain.

## Data model extension

Add a `VisionImage` record with:

- stable local UUID;
- source (`local` or `googlePhotosPicker`);
- local private filename;
- optional Google media identifier for attribution and refresh;
- created and updated dates;
- pinned state and display order.

The Home view should show one image at a time. Rotation belongs in a later preference and must never add visual noise to the default glance.

## CloudKit and iPhone

When the signed iOS/macOS CloudKit targets exist, store small optimized image derivatives as private CloudKit assets. Keep original-resolution photos in the source library. The shared `VisionImage` record then makes the same chosen image available on Mac, iPhone, and widgets without exposing a public URL.

## Current boundary

The current build supports local image selection immediately. Google Photos remains setup-ready, not fake-connected, until the project owner supplies the OAuth client configuration and the app has a registered callback scheme.
