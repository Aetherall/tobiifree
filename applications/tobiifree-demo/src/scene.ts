// scene.ts — three.js background scene with a 3D model of the ET5
// tracker, the configured screen plane, and two eye spheres.
//
// Coordinate convention: tracker-relative millimetres, matching the
// protocol's display_area corners.
//   +x right, +y up (screen-plane), +z out toward the user.
// The tracker is a small bar sitting at the origin.

import * as THREE from 'three';
import type { DisplayArea, GazeSample } from 'tobiifree-sdk-ts';

export type Scene = {
  setDisplayArea: (area: DisplayArea) => void;
  /** Viewport rect inside the display_area, normalized (0..1). */
  setViewportRect: (rect: { x0: number; y0: number; x1: number; y1: number } | null) => void;
  /** Mouse position in viewport-normalized coords (0..1), or null to hide. */
  setMouse: (pos: { nx: number; ny: number } | null) => void;
  setGaze: (sample: GazeSample) => void;
  dispose: () => void;
};

export function createScene(canvas: HTMLCanvasElement): Scene {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setClearColor(0x0b0b0f, 1);

  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0x0b0b0f, 800, 2400);

  const camera = new THREE.PerspectiveCamera(45, 1, 10, 5000);
  // Initial framing: slightly above and behind the tracker, looking at
  // a point ~30 cm in front of it at typical screen height.
  const camTarget = new THREE.Vector3(0, 200, 200);
  const camSpherical = new THREE.Spherical(900, Math.PI * 0.38, Math.PI * 0.5);
  applyCamera();

  function applyCamera() {
    const p = new THREE.Vector3().setFromSpherical(camSpherical).add(camTarget);
    camera.position.copy(p);
    camera.lookAt(camTarget);
  }

  // ---------- lights ----------
  scene.add(new THREE.AmbientLight(0x6a7088, 0.8));
  const keyLight = new THREE.DirectionalLight(0xffffff, 0.9);
  keyLight.position.set(300, 600, 600);
  scene.add(keyLight);
  const fillLight = new THREE.DirectionalLight(0x88aaff, 0.35);
  fillLight.position.set(-400, 200, -200);
  scene.add(fillLight);

  // ---------- ground grid ----------
  const grid = new THREE.GridHelper(2000, 40, 0x2a2a36, 0x1a1a24);
  grid.position.y = 0;
  (grid.material as THREE.Material).transparent = true;
  (grid.material as THREE.Material).opacity = 0.6;
  scene.add(grid);

  // ---------- coordinate frames ----------
  // Everything the device reports (tracker, eyes, gaze rays) lives in
  // the *tracker* frame. The screen plane is authored directly from the
  // display_area corners in that same frame. To visualise the rig with
  // a vertical screen instead of a tilted one, we render tracker+eyes
  // +rays inside a "trackerFrame" group whose transform re-expresses
  // them in the *screen* frame: rotate by -tilt around an x-axis
  // through bl, so the bl edge stays fixed and the screen-plane ends
  // up axis-aligned (tl.z == tr.z == bl.z). Gaze projection operates
  // on the rotated (screen-frame) display area so the dot still lands
  // on the rendered quad.
  //
  // Implemented as two nested groups:
  //   trackerFramePivot  (positioned at bl)
  //     trackerFrame     (rotated by -angle around x)
  //       trackerOffset  (translated by -bl — cancels the pivot)
  const trackerFramePivot = new THREE.Group();
  const trackerFrame = new THREE.Group();
  const trackerOffset = new THREE.Group();
  trackerFramePivot.add(trackerFrame);
  trackerFrame.add(trackerOffset);
  scene.add(trackerFramePivot);

  // ---------- tracker model ----------
  // ET5 is a slim horizontal bar ~285 mm × 15 mm × 15 mm, typically
  // mounted at the bottom edge of a monitor.
  const trackerGroup = new THREE.Group();
  const bar = new THREE.Mesh(
    new THREE.BoxGeometry(285, 15, 18),
    new THREE.MeshStandardMaterial({ color: 0x1a1a22, roughness: 0.4, metalness: 0.6 }),
  );
  trackerGroup.add(bar);
  // Accent stripe on the front face
  const stripe = new THREE.Mesh(
    new THREE.BoxGeometry(200, 3, 0.5),
    new THREE.MeshBasicMaterial({ color: 0x2a6df4 }),
  );
  stripe.position.set(0, 0, 9.2);
  trackerGroup.add(stripe);
  // Two IR "eyes" on the bar
  for (const x of [-80, 80]) {
    const dot = new THREE.Mesh(
      new THREE.CircleGeometry(4, 24),
      new THREE.MeshBasicMaterial({ color: 0x7df9a8 }),
    );
    dot.position.set(x, 0, 9.3);
    trackerGroup.add(dot);
  }
  trackerOffset.add(trackerGroup);

  // ---------- screen plane ----------
  const screenGroup = new THREE.Group();
  const screenGeom = new THREE.BufferGeometry();
  // Triangles: TL-TR-BR, TL-BR-BL (where BR = TR + (BL - TL)).
  screenGeom.setAttribute('position', new THREE.BufferAttribute(new Float32Array(18), 3));
  screenGeom.setIndex([0, 1, 2, 0, 2, 3]);
  screenGeom.computeVertexNormals();
  const screenMesh = new THREE.Mesh(
    screenGeom,
    new THREE.MeshStandardMaterial({
      color: 0x1e2030, roughness: 0.5, metalness: 0.1,
      side: THREE.DoubleSide, transparent: true, opacity: 0.7,
    }),
  );
  screenGroup.add(screenMesh);

  // Screen outline (thin frame)
  const outlineGeom = new THREE.BufferGeometry();
  outlineGeom.setAttribute('position', new THREE.BufferAttribute(new Float32Array(15), 3));
  const outline = new THREE.Line(
    outlineGeom,
    new THREE.LineBasicMaterial({ color: 0x7df9a8 }),
  );
  screenGroup.add(outline);

  // Live gaze dot on the screen plane
  const gazeDot = new THREE.Mesh(
    new THREE.SphereGeometry(8, 16, 16),
    new THREE.MeshBasicMaterial({ color: 0x7df9a8 }),
  );
  gazeDot.visible = false;
  screenGroup.add(gazeDot);

  // Viewport rectangle — shown as a thinner outline floating slightly
  // in front of the screen, at normalized (x0,y0)..(x1,y1) within the
  // display_area. Updated both when the display_area changes and when
  // the user moves/resizes the browser window.
  const viewportGeom = new THREE.BufferGeometry();
  viewportGeom.setAttribute('position', new THREE.BufferAttribute(new Float32Array(15), 3));
  const viewportOutline = new THREE.Line(
    viewportGeom,
    new THREE.LineBasicMaterial({ color: 0x2a6df4, transparent: true, opacity: 0.85 }),
  );
  viewportOutline.visible = false;
  screenGroup.add(viewportOutline);
  let viewportRect: { x0: number; y0: number; x1: number; y1: number } | null = null;

  // Mouse indicator — small orange dot floating just in front of the
  // viewport rect. Position is recomputed from viewport-normalized
  // coords against the current display_area (same math as the gaze
  // dot, but offset into the viewport sub-rectangle).
  const mouseDot = new THREE.Mesh(
    new THREE.SphereGeometry(5, 16, 16),
    new THREE.MeshBasicMaterial({ color: 0xffa44a }),
  );
  mouseDot.visible = false;
  screenGroup.add(mouseDot);
  let mousePos: { nx: number; ny: number } | null = null;

  scene.add(screenGroup);

  // Current display area in *screen frame* — the flattened, vertical
  // version used by gaze projection and mesh positioning. The device
  // still receives the real tilted corners; this is purely visual.
  let currentArea: DisplayArea | null = null;

  // ---------- eyes ----------
  // Placed ~650 mm in front of the tracker at eye height until a gaze
  // sample tells us otherwise.
  const eyesGroup = new THREE.Group();
  const eyeMat = new THREE.MeshStandardMaterial({
    color: 0xf4f0e0, roughness: 0.3, metalness: 0.0,
  });
  const irisMat = new THREE.MeshBasicMaterial({ color: 0x2a5a8a });
  const pupilMat = new THREE.MeshBasicMaterial({ color: 0x050508 });

  function makeEye(): THREE.Group {
    const g = new THREE.Group();
    const sclera = new THREE.Mesh(new THREE.SphereGeometry(12, 24, 16), eyeMat);
    const iris = new THREE.Mesh(new THREE.CircleGeometry(5, 24), irisMat);
    iris.position.z = 11.5;
    const pupil = new THREE.Mesh(new THREE.CircleGeometry(2, 24), pupilMat);
    pupil.position.z = 11.7;
    g.add(sclera);
    g.add(iris);
    g.add(pupil);
    return g;
  }
  const eyeL = makeEye();
  const eyeR = makeEye();
  eyeL.position.set(-32, 300, 650);
  eyeR.position.set( 32, 300, 650);
  eyesGroup.add(eyeL);
  eyesGroup.add(eyeR);
  trackerOffset.add(eyesGroup);

  // Gaze ray lines (origin → display gaze point)
  const rayMat = new THREE.LineBasicMaterial({ color: 0x7df9a8, transparent: true, opacity: 0.5 });
  const rayLGeom = new THREE.BufferGeometry();
  rayLGeom.setAttribute('position', new THREE.BufferAttribute(new Float32Array(6), 3));
  const rayRGeom = new THREE.BufferGeometry();
  rayRGeom.setAttribute('position', new THREE.BufferAttribute(new Float32Array(6), 3));
  const rayL = new THREE.Line(rayLGeom, rayMat);
  const rayR = new THREE.Line(rayRGeom, rayMat);
  rayL.visible = false;
  rayR.visible = false;

  // ---------- track box indicator ----------
  // A small wireframe box near the tracker showing where each eye sits
  // in the normalized [0,1]³ detection volume. Centered = good tracking,
  // edges = about to lose tracking. Data comes from gaze_direction_*_emc
  // which encode normalized track-box position (not direction vectors).
  const TB_W = 80, TB_H = 50, TB_D = 40; // widget size in mm
  const TB_OFFSET_Y = -40; // below the tracker bar

  const trackBoxGroup = new THREE.Group();
  trackBoxGroup.position.set(0, TB_OFFSET_Y, 0);

  // Wireframe edges of the box
  const tbBoxGeom = new THREE.BoxGeometry(TB_W, TB_H, TB_D);
  const tbBoxWire = new THREE.LineSegments(
    new THREE.EdgesGeometry(tbBoxGeom),
    new THREE.LineBasicMaterial({ color: 0x555566, transparent: true, opacity: 0.5 }),
  );
  trackBoxGroup.add(tbBoxWire);

  // Eye position dots inside the box
  const tbDotL = new THREE.Mesh(
    new THREE.SphereGeometry(3, 12, 8),
    new THREE.MeshBasicMaterial({ color: 0xff6688 }),
  );
  const tbDotR = new THREE.Mesh(
    new THREE.SphereGeometry(3, 12, 8),
    new THREE.MeshBasicMaterial({ color: 0x66aaff }),
  );
  tbDotL.visible = false;
  tbDotR.visible = false;
  trackBoxGroup.add(tbDotL);
  trackBoxGroup.add(tbDotR);

  trackerOffset.add(trackBoxGroup);

  // ---------- real-size track box (surrounds the eyes) ----------
  // From the linear model: x_range ≈ 457mm, y_range ≈ 463mm, z_range ≈ 503mm.
  // The z centre is at ~0.78×503 ≈ 393mm offset from the tracker origin,
  // so the box spans roughly z = 393 − 251 .. 393 + 251 = 142..644 mm.
  // x is centred at 0 (symmetric), y centred at ~0.5×463 ≈ 231mm.
  const RTB_W = 457, RTB_H = 463, RTB_D = 503;
  const RTB_CX = 0, RTB_CY = 0.5 * RTB_H, RTB_CZ = 0.78 * RTB_D;

  const realTrackBox = new THREE.Group();
  realTrackBox.position.set(RTB_CX, RTB_CY, RTB_CZ);

  const rtbGeom = new THREE.BoxGeometry(RTB_W, RTB_H, RTB_D);
  const rtbWire = new THREE.LineSegments(
    new THREE.EdgesGeometry(rtbGeom),
    new THREE.LineBasicMaterial({ color: 0x444455, transparent: true, opacity: 0.25 }),
  );
  realTrackBox.add(rtbWire);

  // Eye dots in the real track box
  const rtbDotL = new THREE.Mesh(
    new THREE.SphereGeometry(6, 12, 8),
    new THREE.MeshBasicMaterial({ color: 0xff6688, transparent: true, opacity: 0.5 }),
  );
  const rtbDotR = new THREE.Mesh(
    new THREE.SphereGeometry(6, 12, 8),
    new THREE.MeshBasicMaterial({ color: 0x66aaff, transparent: true, opacity: 0.5 }),
  );
  rtbDotL.visible = false;
  rtbDotR.visible = false;
  realTrackBox.add(rtbDotL);
  realTrackBox.add(rtbDotR);

  trackerOffset.add(realTrackBox);

  // Gaze rays live at scene root so their endpoints are written in world
  // (screen-frame) coords directly — eye endpoints come from
  // getWorldPosition of the framed eye groups; gaze endpoints are the
  // already-screen-frame projection.
  scene.add(rayL);
  scene.add(rayR);


  // ---------- update helpers ----------
  function setDisplayArea(area: DisplayArea) {
    // Rotation that takes tracker-frame → screen-frame: around the x-
    // axis passing through bl, by -atan2(tilt, height). Applying it to
    // the screen's top corners gives a vertical panel at z = bl.z.
    // We apply the same rotation to tracker+eyes+rays via a pivot
    // group so they move together with the screen.
    const dy = area.tl.y - area.bl.y;
    const dz = area.tl.z - area.bl.z;
    const angle = Math.atan2(dz, dy); // screen top leans away by +angle
    trackerFramePivot.position.set(area.bl.x, area.bl.y, area.bl.z);
    trackerFrame.rotation.x = -angle;
    trackerOffset.position.set(-area.bl.x, -area.bl.y, -area.bl.z);

    // Flatten the screen to the bl.z plane. The flat top-corner y
    // preserves the edge length of the tilted panel so it doesn't
    // visually shrink as you tilt.
    const flatDy = Math.hypot(dy, dz) * (dy >= 0 ? 1 : -1);
    const flatTl = { x: area.tl.x, y: area.bl.y + flatDy, z: area.bl.z };
    const flatTr = { x: area.tr.x, y: area.bl.y + flatDy, z: area.bl.z };
    const flatBl = { x: area.bl.x, y: area.bl.y, z: area.bl.z };
    currentArea = { tl: flatTl, tr: flatTr, bl: flatBl };
    const { tl, tr, bl } = currentArea;
    const br = { x: tr.x + (bl.x - tl.x), y: tr.y + (bl.y - tl.y), z: tr.z + (bl.z - tl.z) };
    const pos = screenMesh.geometry.getAttribute('position') as THREE.BufferAttribute;
    // TL, TR, BR, BL
    pos.setXYZ(0, tl.x, tl.y, tl.z);
    pos.setXYZ(1, tr.x, tr.y, tr.z);
    pos.setXYZ(2, br.x, br.y, br.z);
    pos.setXYZ(3, bl.x, bl.y, bl.z);
    pos.needsUpdate = true;
    screenMesh.geometry.computeVertexNormals();
    screenMesh.geometry.computeBoundingSphere();

    const opos = outline.geometry.getAttribute('position') as THREE.BufferAttribute;
    opos.setXYZ(0, tl.x, tl.y, tl.z);
    opos.setXYZ(1, tr.x, tr.y, tr.z);
    opos.setXYZ(2, br.x, br.y, br.z);
    opos.setXYZ(3, bl.x, bl.y, bl.z);
    opos.setXYZ(4, tl.x, tl.y, tl.z);
    opos.needsUpdate = true;
    outline.geometry.computeBoundingSphere();

    // Re-centre the camera target on the middle of the display.
    camTarget.set(
      (tl.x + tr.x + bl.x + br.x) / 4,
      (tl.y + tr.y + bl.y + br.y) / 4,
      (tl.z + tr.z + bl.z + br.z) / 4,
    );
    applyCamera();

    refreshViewportOutline();
    refreshMouseDot();
  }

  function refreshViewportOutline() {
    if (!currentArea || !viewportRect) { viewportOutline.visible = false; return; }
    const { tl, tr, bl } = currentArea;
    const proj = (nx: number, ny: number) => ({
      x: tl.x + nx * (tr.x - tl.x) + ny * (bl.x - tl.x),
      y: tl.y + nx * (tr.y - tl.y) + ny * (bl.y - tl.y),
      z: tl.z + nx * (tr.z - tl.z) + ny * (bl.z - tl.z) + 0.8, // nudge forward
    });
    const { x0, y0, x1, y1 } = viewportRect;
    const p00 = proj(x0, y0), p10 = proj(x1, y0);
    const p11 = proj(x1, y1), p01 = proj(x0, y1);
    const arr = viewportGeom.getAttribute('position') as THREE.BufferAttribute;
    arr.setXYZ(0, p00.x, p00.y, p00.z);
    arr.setXYZ(1, p10.x, p10.y, p10.z);
    arr.setXYZ(2, p11.x, p11.y, p11.z);
    arr.setXYZ(3, p01.x, p01.y, p01.z);
    arr.setXYZ(4, p00.x, p00.y, p00.z);
    arr.needsUpdate = true;
    viewportGeom.computeBoundingSphere();
    viewportOutline.visible = true;
  }

  function setViewportRect(rect: { x0: number; y0: number; x1: number; y1: number } | null) {
    viewportRect = rect;
    refreshViewportOutline();
    refreshMouseDot();
  }

  function refreshMouseDot() {
    if (!currentArea || !mousePos) { mouseDot.visible = false; return; }
    // Map viewport-normalized coords → display-normalized coords via
    // the viewport rect (default full-screen if unset).
    const vr = viewportRect ?? { x0: 0, y0: 0, x1: 1, y1: 1 };
    const dx = vr.x0 + mousePos.nx * (vr.x1 - vr.x0);
    const dy = vr.y0 + mousePos.ny * (vr.y1 - vr.y0);
    const { tl, tr, bl } = currentArea;
    mouseDot.position.set(
      tl.x + dx * (tr.x - tl.x) + dy * (bl.x - tl.x),
      tl.y + dx * (tr.y - tl.y) + dy * (bl.y - tl.y),
      tl.z + dx * (tr.z - tl.z) + dy * (bl.z - tl.z) + 1.6,
    );
    mouseDot.visible = true;
  }

  function setMouse(pos: { nx: number; ny: number } | null) {
    mousePos = pos;
    refreshMouseDot();
  }

  // Project normalized 2d (0..1) onto the display_area plane.
  function projectNorm(nx: number, ny: number): THREE.Vector3 | null {
    if (!currentArea) return null;
    const { tl, tr, bl } = currentArea;
    // (0,0) = TL, (1,0) = TR, (0,1) = BL.
    return new THREE.Vector3(
      tl.x + nx * (tr.x - tl.x) + ny * (bl.x - tl.x),
      tl.y + nx * (tr.y - tl.y) + ny * (bl.y - tl.y),
      tl.z + nx * (tr.z - tl.z) + ny * (bl.z - tl.z),
    );
  }

  function setGaze(s: GazeSample) {
    // Eye positions
    if (s.eye_origin_L_mm) {
      eyeL.position.set(s.eye_origin_L_mm.x, s.eye_origin_L_mm.y, s.eye_origin_L_mm.z);
    }
    if (s.eye_origin_R_mm) {
      eyeR.position.set(s.eye_origin_R_mm.x, s.eye_origin_R_mm.y, s.eye_origin_R_mm.z);
    }


    // Track box indicator: map normalized [0,1]³ → widget box coords.
    // emc encodes: x ≈ 0.5 when centered horizontally, y ≈ 0.5 centered
    // vertically, z ≈ depth. We map (0,0,0)→(-W/2,-H/2,-D/2) and
    // (1,1,1)→(+W/2,+H/2,+D/2). Note x is inverted (0.5−eye/scale).
    const dL = s.gaze_direction_L_emc;
    const dR = s.gaze_direction_R_emc;
    if (dL && s.validity_L === 0) {
      tbDotL.position.set(-(dL.x - 0.5) * TB_W, -(dL.y - 0.5) * TB_H, dL.z * TB_D);
      tbDotL.visible = true;
      rtbDotL.position.set((0.5 - dL.x) * RTB_W, (0.5 - dL.y) * RTB_H, (dL.z - 0.5) * RTB_D);
      rtbDotL.visible = true;
    } else {
      tbDotL.visible = false;
      rtbDotL.visible = false;
    }
    if (dR && s.validity_R === 0) {
      tbDotR.position.set(-(dR.x - 0.5) * TB_W, -(dR.y - 0.5) * TB_H, dR.z * TB_D);
      tbDotR.visible = true;
      rtbDotR.position.set((0.5 - dR.x) * RTB_W, (0.5 - dR.y) * RTB_H, (dR.z - 0.5) * RTB_D);
      rtbDotR.visible = true;
    } else {
      tbDotR.visible = false;
      rtbDotR.visible = false;
    }

    const p2 = s.gaze_point_2d_norm;
    const valid = s.validity_L === 0 || s.validity_R === 0;

    if (p2 && valid) {
      const world = projectNorm(p2.x, p2.y);
      if (world) {
        gazeDot.position.copy(world);
        gazeDot.visible = true;
        // Orient each eye toward the gaze point
        eyeL.lookAt(world);
        eyeR.lookAt(world);

        // Draw gaze rays from each eye origin (in world space) to the
        // gaze point (already in world/screen-frame space).
        const lp = new THREE.Vector3();
        const rp = new THREE.Vector3();
        trackerFramePivot.updateMatrixWorld();
        eyeL.getWorldPosition(lp);
        eyeR.getWorldPosition(rp);
        const lArr = rayLGeom.getAttribute('position') as THREE.BufferAttribute;
        lArr.setXYZ(0, lp.x, lp.y, lp.z);
        lArr.setXYZ(1, world.x, world.y, world.z);
        lArr.needsUpdate = true;
        const rArr = rayRGeom.getAttribute('position') as THREE.BufferAttribute;
        rArr.setXYZ(0, rp.x, rp.y, rp.z);
        rArr.setXYZ(1, world.x, world.y, world.z);
        rArr.needsUpdate = true;
        rayL.visible = true;
        rayR.visible = true;
      }
    } else {
      gazeDot.visible = false;
      rayL.visible = false;
      rayR.visible = false;
    }

  }

  // ---------- camera controls ----------
  // Right-drag: orbit (yaw + pitch). Scroll: zoom (radius). Space+drag: pan.
  let spaceDown = false;
  let dragging: null | 'rotate' | 'pan' = null;
  let lastX = 0;
  let lastY = 0;

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.code === 'Space') { spaceDown = true; }
  };
  const onKeyUp = (e: KeyboardEvent) => {
    if (e.code === 'Space') { spaceDown = false; }
  };
  window.addEventListener('keydown', onKeyDown);
  window.addEventListener('keyup', onKeyUp);

  const onPointerDown = (e: PointerEvent) => {
    if (spaceDown) {
      dragging = 'pan';
      canvas.classList.add('panning');
    } else if (e.button === 2) {
      dragging = 'rotate';
      canvas.classList.add('rotating');
    } else {
      return;
    }
    lastX = e.clientX;
    lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
    e.preventDefault();
  };
  const onPointerMove = (e: PointerEvent) => {
    if (!dragging) return;
    const dx = e.clientX - lastX;
    const dy = e.clientY - lastY;
    lastX = e.clientX;
    lastY = e.clientY;
    if (dragging === 'rotate') {
      camSpherical.theta -= dx * 0.005;
      camSpherical.phi -= dy * 0.005;
      camSpherical.phi = Math.max(0.05, Math.min(Math.PI - 0.05, camSpherical.phi));
      applyCamera();
    } else if (dragging === 'pan') {
      // Move target in camera's local x/y plane.
      const panScale = camSpherical.radius * 0.0015;
      const right = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0);
      const up = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1);
      camTarget.addScaledVector(right, -dx * panScale);
      camTarget.addScaledVector(up, dy * panScale);
      applyCamera();
    }
  };
  const onPointerUp = (e: PointerEvent) => {
    if (!dragging) return;
    dragging = null;
    canvas.classList.remove('panning', 'rotating');
    canvas.releasePointerCapture(e.pointerId);
  };
  const onWheel = (e: WheelEvent) => {
    e.preventDefault();
    const k = Math.exp(e.deltaY * 0.001);
    camSpherical.radius = Math.max(100, Math.min(4000, camSpherical.radius * k));
    applyCamera();
  };
  const onContextMenu = (e: MouseEvent) => e.preventDefault();

  canvas.addEventListener('pointerdown', onPointerDown);
  canvas.addEventListener('pointermove', onPointerMove);
  canvas.addEventListener('pointerup', onPointerUp);
  canvas.addEventListener('pointercancel', onPointerUp);
  canvas.addEventListener('wheel', onWheel, { passive: false });
  canvas.addEventListener('contextmenu', onContextMenu);

  // ---------- render loop ----------
  function resize() {
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  const ro = new ResizeObserver(resize);
  ro.observe(canvas);
  resize();

  let raf = 0;
  const tick = () => {
    renderer.render(scene, camera);
    raf = requestAnimationFrame(tick);
  };
  tick();

  // Seed with a reasonable default display area so the plane is visible
  // before the device reports one.
  setDisplayArea({
    tl: { x: -200, y: 300, z: 0 },
    tr: { x:  200, y: 300, z: 0 },
    bl: { x: -200, y:   0, z: 0 },
  });

  return {
    setDisplayArea,
    setViewportRect,
    setMouse,
    setGaze,
    dispose() {
      cancelAnimationFrame(raf);
      ro.disconnect();
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      canvas.removeEventListener('pointerdown', onPointerDown);
      canvas.removeEventListener('pointermove', onPointerMove);
      canvas.removeEventListener('pointerup', onPointerUp);
      canvas.removeEventListener('pointercancel', onPointerUp);
      canvas.removeEventListener('wheel', onWheel);
      canvas.removeEventListener('contextmenu', onContextMenu);
      renderer.dispose();
    },
  };
}
