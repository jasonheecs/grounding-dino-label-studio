# Label Studio + Grounding DINO setup

Local Label Studio deployment with a zero-shot object detection ML backend
([Grounding DINO](https://github.com/IDEA-Research/GroundingDINO)) wired up for
labeling bounding boxes on images. Grounding DINO detects objects from a
free-text prompt (e.g. `watermelon.`).

## Services

- **`label-studio`** — the Label Studio server (`heartexlabs/label-studio:latest`), on `http://localhost:8080`. Data persists in `./mydata`.
- **`grounding-dino-ml-backend`** — the ML backend, on `http://localhost:9090` (`http://grounding-dino-ml-backend:9090` from inside the Docker network). Built from `./label-studio-ml-backend/label_studio_ml/examples/grounding_dino`, with a couple of local fixes on top (see below). Model weights/cache persist in `./mydata/grounding-dino`.

## First-time setup

1. Create a `.env` file with:
   ```
   LABEL_STUDIO_API_KEY=<a Label Studio refresh token, only used for its own settings/admin calls>
   LABEL_STUDIO_LEGACY_TOKEN=<a non-expiring legacy API token — see "Auth" below for why>
   ```
2. Run `./start.sh` — clones `label-studio-ml-backend` (if not already present), checks out the pinned base commit, applies our local fixes patch (see [patches/](patches/) and "Local patches" below), then builds and starts everything with `docker compose up -d --build`. Safe to re-run any time — it skips the clone/patch steps if they're already done.
3. In Label Studio (`http://localhost:8080`), open your project → Settings → Machine Learning → Add Model, pointing at `http://grounding-dino-ml-backend:9090`. Enable **interactive predictions**.

<details>
<summary>What <code>start.sh</code> does under the hood / doing it manually</summary>

```
git clone https://github.com/HumanSignal/label-studio-ml-backend
cd label-studio-ml-backend
git checkout "$(cat ../patches/grounding-dino-local-fixes.commit)"
git apply ../patches/grounding-dino-local-fixes.patch
cd ..
docker compose up -d --build
```

</details>

## Labeling config

The project's labeling config needs a prompt box plus rectangle labels for
each fruit class, e.g.:

```xml
<View>
    <View className="prompt">
        <Header value="Enter a prompt to detect objects in the image:"/>
        <TextArea name="prompt" toName="image" editable="true" rows="2" maxSubmissions="1" showSubmitButton="true"/>
    </View>
    <Image name="image" value="$image"/>
    <RectangleLabels name="label" toName="image">
        <Label value="mango" background="orange"/>
        <Label value="orange" background="purple"/>
        <Label value="apple" background="red"/>
        <Label value="kiwi" background="green"/>
        <Label value="watermelon" background="pink"/>
    </RectangleLabels>
</View>
```

**Usage notes:**
- Turn on **Auto-Annotation** (toggle at the bottom of the labeling screen) — without it, typing a prompt does nothing.
- Type the prompt in Grounding DINO's expected format — lowercase, period-terminated, one noun per class (e.g. `watermelon.`) — then click the submit button next to the text box. A full sentence like "detect watermelons" tends to produce one low-confidence box spanning the whole image instead of individual detections.
- `maxSubmissions="1"` on the `TextArea` means each task only accepts one prompt submission. To retry with a different prompt on the same task, delete the existing region/draft first.

## Auth

`LABEL_STUDIO_ACCESS_TOKEN`/`LABEL_STUDIO_API_KEY` are set to a **legacy API
token**, not the default JWT refresh token Label Studio shows you by default.
The ML backend sends whatever token it's given straight through as a Bearer
credential to fetch task images — refresh tokens aren't valid for that (only
short-lived access tokens are, which expire in 5 minutes — too short to
hardcode). `LABEL_STUDIO_ENABLE_LEGACY_API_TOKEN=true` is set on the
`label-studio` service to allow generating one; enable it for the org via
Django admin or `POST /api/jwt/settings` if not already on, then set
`LABEL_STUDIO_LEGACY_TOKEN` in `.env` to that token.

## Local patches on top of the upstream `grounding_dino` example

`label-studio-ml-backend/` itself is not committed to this repo (it's
`git clone`'d locally per the setup steps above, and gitignored) — instead,
our fixes on top of it live as a patch at
[patches/grounding-dino-local-fixes.patch](patches/grounding-dino-local-fixes.patch),
pinned against the upstream commit recorded in
[patches/grounding-dino-local-fixes.commit](patches/grounding-dino-local-fixes.commit).
The pin matters because a fresh `git clone` today would land on whatever
upstream's current `master` is, not the commit this patch was written against —
applying it against a divergent tree could fail or silently apply with fuzz.

If you need to regenerate the patch after further local edits: diff the
modified files in your working `label-studio-ml-backend/` against a pristine
clone checked out at the same pinned commit (`git diff --no-index` or
`diff -u --label a/... --label b/...`), and update the `.commit` file if you
also bump the pinned base commit.

The patch applies these fixes on top of upstream (`HumanSignal/label-studio-ml-backend`):

- **`Dockerfile`**: dropped `RUN conda update conda -y` — its dependency solver OOM-killed the build on machines with Docker Desktop memory allocations under ~5GB, and it only updates conda itself, not any real project dependency. Also pinned `numpy<2` and `transformers==4.39.3` — groundingdino's unpinned deps otherwise pull in versions incompatible with the pinned `torch==2.1.2` build (numpy 2.x ABI break; transformers too new for the BERT text-encoder loading path).
- **`dino.py`**:
  - `predict()` was missing a `return` after building the empty-prompt `ModelResponse`, so it fell through to calling the model with `caption=None` and crashed. Fixed by adding the `return`.
  - `get_results()` never attached a `rectanglelabels` value to detected boxes, so every detection showed as "No label" regardless of what was detected. Fixed by capturing the `phrases` Grounding DINO returns (previously discarded) and matching each one against the project's configured `RectangleLabels` values.

## Known limitations / open items

- **Large images can OOM the backend.** Docker Desktop's memory allocation (~4.8GB) is tight for Grounding DINO's CPU inference on multi-megapixel images. Raising Docker Desktop's memory limit (Settings → Resources → Memory → 8GB+) helps
- **Dense, near-identical objects (e.g. many touching fruit slices) can under-detect** — Grounding DINO does no NMS/box-merging, so this shows up as too few boxes rather than merged ones. Tuning options, cheapest first: rephrase the prompt (see above), lower `BOX_THRESHOLD`/`TEXT_THRESHOLD` further (currently `0.20`/`0.20`), or switch to the larger `SwinB` checkpoint (already downloaded in the image — set `GROUNDING_DINO_CONFIG=GroundingDINO_SwinB_cfg.py` and `GROUNDING_DINO_WEIGHTS=groundingdino_swinb_cogcoor.pth`). If it still under-detects after all of that, that's a real limit of zero-shot grounding models on this kind of scene, not a config problem — manual correction is the fallback.
