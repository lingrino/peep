#version 330 core

uniform vec2 uResolution;
uniform float uTime;
out vec4 fragColor;

// Animated diagonal gradient.
void main() {
    vec2 uv = gl_FragCoord.xy / uResolution;
    float t = 0.5 + 0.5 * sin(uTime + uv.x * 3.14159);
    vec3 color = mix(vec3(0.2, 0.3, 0.9), vec3(0.95, 0.4, 0.3), t * uv.y);
    fragColor = vec4(color, 1.0);
}
