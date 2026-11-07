#ifdef GL_ES
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

#pragma parameter profile "Color Profile (1=sRGB, 2=DCI, 3=Rec2020)" 1.0 1.0 3.0 1.0
#pragma parameter darken_screen "Screen Darkness" 0.0 0.0 2.2 0.1
#ifdef PARAMETER_UNIFORM
uniform COMPAT_PRECISION float profile;
uniform COMPAT_PRECISION float darken_screen;
#else
#define profile 1.0
#define darken_screen 0.0
#endif

#define GAMMA 2.2
#define INV_GAMMA (1.0 / GAMMA)
#define INV_GAMMA_SQ (1.0 / (GAMMA * GAMMA))

#if defined(VERTEX)

#if __VERSION__ >= 130
#define COMPAT_VARYING out
#define COMPAT_ATTRIBUTE in
#define COMPAT_TEXTURE texture
#else
#define COMPAT_VARYING varying
#define COMPAT_ATTRIBUTE attribute
#define COMPAT_TEXTURE texture2D
#endif

#ifdef GL_ES
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

COMPAT_ATTRIBUTE vec4 VertexCoord;
COMPAT_ATTRIBUTE vec4 COLOR;
COMPAT_ATTRIBUTE vec4 TexCoord;
COMPAT_VARYING vec4 COL0;
COMPAT_VARYING vec4 TEX0;

uniform mat4 MVPMatrix;
uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;

void main()
{
    gl_Position = MVPMatrix * VertexCoord;
    COL0 = COLOR;
    TEX0.xy = TexCoord.xy;
}

#elif defined(FRAGMENT)

#if __VERSION__ >= 130
#define COMPAT_VARYING in
#define COMPAT_TEXTURE texture
out vec4 FragColor;
#else
#define COMPAT_VARYING varying
#define FragColor gl_FragColor
#define COMPAT_TEXTURE texture2D
#endif

#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;
uniform sampler2D Texture;
COMPAT_VARYING vec4 TEX0;

#define Source Texture
#define vTexCoord TEX0.xy

const mat3 SP1_sRGB = mat3(
    0.96,   0.0325, 0.001,
    0.11,   0.89,   -0.03,
    -0.07,  0.0775, 1.029
);

const mat3 SP1_DCI = mat3(
    0.805,  0.0675, 0.017,
    0.24,   0.86,   0.02,
    -0.045, 0.0725, 0.963
);

const mat3 SP1_Rec2020 = mat3(
    0.625, 0.10, 0.015,
    0.35,  0.82, 0.0325,
    0.025, 0.08, 0.9525
);

const float sRGB_lum = 0.935;
const float DCI_lum = 0.955;
const float Rec2020_lum = 1.0;

void main()
{
    vec3 texel = COMPAT_TEXTURE(Source, vTexCoord).rgb;

    vec3 screen = pow(texel, vec3(GAMMA));

    int color_mode = int(floor(profile + 0.5));

    if (color_mode == 1) screen = SP1_sRGB * screen * sRGB_lum;
    else if (color_mode == 2) screen = SP1_DCI * screen * DCI_lum;
    else if (color_mode == 3) screen = SP1_Rec2020 * screen * Rec2020_lum;

    screen = clamp(screen, 0.0, 1.0);

    float final_gamma = darken_screen * INV_GAMMA_SQ + INV_GAMMA;

    screen = pow(screen, vec3(final_gamma));

    FragColor = vec4(screen, 1.0);
}
#endif
