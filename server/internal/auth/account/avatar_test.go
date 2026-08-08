package account

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

func TestValidAvatarPayloadChecksFormatAndDimensions(t *testing.T) {
	jpegPayload := encodedJPEG(t, 2, 2)
	pngPayload := encodedPNG(t, 2, 2)
	webPPayload := syntheticWebPVP8X(2, 2)

	tests := []struct {
		name        string
		contentType string
		payload     []byte
		want        bool
	}{
		{name: "jpeg", contentType: "image/jpeg", payload: jpegPayload, want: true},
		{name: "png", contentType: "image/png", payload: pngPayload, want: true},
		{name: "webp dimensions", contentType: "image/webp", payload: webPPayload, want: true},
		{name: "spoofed png", contentType: "image/png", payload: []byte("not really a png"), want: false},
		{name: "jpeg bytes cannot claim png", contentType: "image/png", payload: jpegPayload, want: false},
		{name: "svg rejected", contentType: "image/svg+xml", payload: []byte("<svg></svg>"), want: false},
		{name: "oversized width", contentType: "image/png", payload: encodedPNG(t, MaxProfileAvatarWidth+1, 1), want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := validAvatarPayload(test.contentType, test.payload); got != test.want {
				t.Fatalf("validAvatarPayload(%q)=%v want %v", test.contentType, got, test.want)
			}
		})
	}
}

func TestWebPDimensionsRejectsOversizedCanvas(t *testing.T) {
	payload := syntheticWebPVP8X(MaxProfileAvatarWidth+1, 1)
	if validAvatarPayload("image/webp", payload) {
		t.Fatal("oversized WebP canvas was accepted")
	}
}

func encodedJPEG(t *testing.T, width, height int) []byte {
	t.Helper()
	var buffer bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	img.Set(0, 0, color.White)
	if err := jpeg.Encode(&buffer, img, &jpeg.Options{Quality: 80}); err != nil {
		t.Fatalf("encode jpeg: %v", err)
	}
	return buffer.Bytes()
}

func encodedPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	var buffer bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	img.Set(0, 0, color.White)
	if err := png.Encode(&buffer, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buffer.Bytes()
}

func syntheticWebPVP8X(width, height int) []byte {
	payload := make([]byte, 30)
	copy(payload[0:4], "RIFF")
	binary.LittleEndian.PutUint32(payload[4:8], uint32(len(payload)-8))
	copy(payload[8:12], "WEBP")
	copy(payload[12:16], "VP8X")
	binary.LittleEndian.PutUint32(payload[16:20], 10)
	writeUint24(payload[24:27], width-1)
	writeUint24(payload[27:30], height-1)
	return payload
}

func writeUint24(target []byte, value int) {
	target[0] = byte(value)
	target[1] = byte(value >> 8)
	target[2] = byte(value >> 16)
}
