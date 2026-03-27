import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "startButton",
    "stopButton",
    "video",
    "canvas",
    "status",
    "qrUrl",
    "pageTitle",
    "youtubeResult",
    "youtubePlay",
    "youtubeLink",
    "youtubeFrame"
  ]

  connect() {
    this._stream = null
    this._raf = null
    this._lastValue = null
    this._detector = null
    this._youtubeVideoId = null

    if ("BarcodeDetector" in window) {
      try {
        this._detector = new window.BarcodeDetector({ formats: ["qr_code"] })
      } catch (_) {
        this._detector = null
      }
    } else {
      // Older browsers: we can't decode QR from the canvas without additional libs.
      this._setStatus("QR scanning not supported in this browser.")
    }

    // Avoid `data-action` so Stimulus LSP doesn't complain about method resolution.
    this._startClickHandler = () => this.startCamera()
    this._stopClickHandler = () => this.stopCamera()
    this._playClickHandler = () => this.playYoutube()

    if (this.hasStartButtonTarget) this.startButtonTarget.addEventListener("click", this._startClickHandler)
    if (this.hasStopButtonTarget) this.stopButtonTarget.addEventListener("click", this._stopClickHandler)
    if (this.hasYoutubePlayTarget) this.youtubePlayTarget.addEventListener("click", this._playClickHandler)
  }

  disconnect() {
    if (this.hasStartButtonTarget) this.startButtonTarget.removeEventListener("click", this._startClickHandler)
    if (this.hasStopButtonTarget) this.stopButtonTarget.removeEventListener("click", this._stopClickHandler)
    if (this.hasYoutubePlayTarget) this.youtubePlayTarget.removeEventListener("click", this._playClickHandler)
    this.stopCamera()
  }

  startCamera() {
    return this._startCamera()
  }

  async _startCamera() {
    if (this._stream) return

    this._setStatus("Requesting camera permission…")
    this._clearOutputs()

    try {
      this._stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: "environment" },
        audio: false
      })
      this.videoTarget.srcObject = this._stream
      await this.videoTarget.play()
      this._setStatus("Scanning…")
      this._scanLoop()
    } catch (e) {
      this._setStatus(`Camera error: ${e?.message || e}`)
      this._stream = null
    }
  }

  stopCamera() {
    this._stopCamera()
  }

  _stopCamera() {
    if (this._raf) cancelAnimationFrame(this._raf)
    this._raf = null

    if (this._stream) {
      for (const track of this._stream.getTracks()) track.stop()
    }
    this._stream = null
    this._stopYoutube()
    this._setStatus("Stopped")
  }

  async _scanLoop() {
    if (!this._stream) return

    const video = this.videoTarget
    if (video.readyState < 2) {
      this._raf = requestAnimationFrame(() => this._scanLoop())
      return
    }

    const width = video.videoWidth || 640
    const height = video.videoHeight || 480

    const canvas = this.canvasTarget
    canvas.width = width
    canvas.height = height
    const ctx = canvas.getContext("2d", { willReadFrequently: true })
    ctx.drawImage(video, 0, 0, width, height)

    let value = null

    if (this._detector) {
      try {
        const codes = await this._detector.detect(canvas)
        value = codes?.[0]?.rawValue || null
      } catch (_) {
        value = null
      }
    }

    if (value && value !== this._lastValue) {
      this._lastValue = value
      await this._handleQrValue(value)
    }

    this._raf = requestAnimationFrame(() => this._scanLoop())
  }

  async _handleQrValue(value) {
    this._setStatus("QR detected. Resolving title…")

    const url = this._normalizeUrl(value)
    if (!url) {
      this._setStatus("QR detected, but it doesn’t look like a URL.")
      return
    }

    this.qrUrlTarget.textContent = url
    this.qrUrlTarget.href = url

    this.pageTitleTarget.textContent = "Loading…"
    this.youtubeResultTarget.textContent = "—"
    this._stopYoutube()

    const titleResp = await fetch(`/api/title?url=${encodeURIComponent(url)}`, {
      headers: { "Accept": "application/json" }
    })

    const titleJson = await titleResp.json().catch(() => ({}))
    const title = titleJson?.title || null
    this.pageTitleTarget.textContent = title || "—"

    if (!title) {
      this._setStatus("Couldn’t extract a title from that page.")
      return
    }

    this._setStatus("Searching YouTube…")
    const ytResp = await fetch(`/api/youtube_first?query=${encodeURIComponent(title)}`, {
      headers: { "Accept": "application/json" }
    })
    const ytJson = await ytResp.json().catch(() => ({}))

    const videoId = ytJson?.videoId || null
    this.youtubeResultTarget.textContent = JSON.stringify(ytJson, null, 2)

    if (!videoId) {
      this._setStatus("Couldn’t find a YouTube result for that title.")
      return
    }

    this._youtubeVideoId = videoId
    const embedUrl = ytJson?.embedUrl || `https://www.youtube.com/embed/${videoId}?autoplay=1&playsinline=1&mute=0`

    this.youtubeLinkTarget.href = ytJson?.url || `https://www.youtube.com/watch?v=${videoId}`
    this.youtubeLinkTarget.textContent = "Open video"
    this.youtubePlayTarget.disabled = false

    // Try to autoplay immediately. If the browser blocks audio autoplay, the Play button will still work.
    this.youtubeFrameTarget.src = embedUrl
    this._setStatus("Attempting playback (still scanning).")
  }

  _normalizeUrl(raw) {
    const v = String(raw || "").trim()
    if (!v) return null

    try {
      const u = new URL(v)
      if (u.protocol === "http:" || u.protocol === "https:") return u.toString()
      return null
    } catch (_) {
      // Accept bare domains
      try {
        const u = new URL(`https://${v}`)
        return u.toString()
      } catch (_) {
        return null
      }
    }
  }

  _setStatus(text) {
    this.statusTarget.textContent = text
  }

  _clearOutputs() {
    this.qrUrlTarget.textContent = "—"
    this.qrUrlTarget.href = "about:blank"
    this.pageTitleTarget.textContent = "—"
    this.youtubeResultTarget.textContent = "—"
    this._stopYoutube()
  }

  playYoutube() {
    if (!this._youtubeVideoId) return

    // User gesture: this is our best chance to get audio to start.
    this.youtubeFrameTarget.src = `https://www.youtube.com/embed/${this._youtubeVideoId}?autoplay=1&playsinline=1&mute=0`
    this.youtubePlayTarget.disabled = true
    this._setStatus("Playing on YouTube…")
  }

  _stopYoutube() {
    this._youtubeVideoId = null
    if (this.hasYoutubeFrameTarget) this.youtubeFrameTarget.src = "about:blank"
    if (this.hasYoutubePlayTarget) this.youtubePlayTarget.disabled = true
    if (this.hasYoutubeLinkTarget) {
      this.youtubeLinkTarget.href = "about:blank"
      this.youtubeLinkTarget.textContent = "Open video"
    }
  }
}
