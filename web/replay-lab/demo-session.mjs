export const demoSession = {
  sport: "Longboard",
  duration: "18:42",
  devices: [
    { id: "watch", name: "Apple Watch", detail: "wrist IMU + HR", state: "ready", rate: "50 Hz", battery: 74, syncMs: 2.8 },
    { id: "pod", name: "Equipment Pod", detail: "board-center", state: "ready", rate: "100 Hz", battery: 82, syncMs: 2.1 },
    { id: "left", name: "Left Insole", detail: "pressure + IMU", state: "ready", rate: "100 Hz", battery: 67, syncMs: 3.2 },
    { id: "right", name: "Right Insole", detail: "pressure + IMU", state: "degraded", rate: "96 Hz", battery: 61, syncMs: 7.6 }
  ],
  requiredIds: ["watch", "pod", "left", "right"],
  frames: [
    {
      t: 0,
      hr: 126,
      speed: 1.4,
      boardRoll: 0,
      poseConfidence: 0.91,
      syncMs: 3.2,
      leftLoad: 0.49,
      rightLoad: 0.51,
      copL: [46, 72],
      copR: [55, 70],
      pressureL: [24,31,35,29,42,51,48,56,61,62,54,47,44,39,36,32],
      pressureR: [26,33,36,31,44,52,49,58,64,65,57,49,46,41,38,34],
      joints: {
        head: [50, 18], neck: [50, 30], pelvis: [51, 58],
        leftHand: [29, 50], rightHand: [75, 48],
        leftFoot: [39, 88], rightFoot: [65, 88]
      }
    },
    {
      t: 2500,
      hr: 149,
      speed: 6.8,
      boardRoll: -12.5,
      poseConfidence: 0.87,
      syncMs: 3.7,
      leftLoad: 0.38,
      rightLoad: 0.62,
      copL: [40, 65],
      copR: [63, 62],
      pressureL: [18,23,29,20,31,39,37,42,46,45,39,35,31,28,25,21],
      pressureR: [39,49,55,47,63,72,69,78,84,86,77,67,62,58,53,46],
      joints: {
        head: [45, 18], neck: [47, 30], pelvis: [54, 58],
        leftHand: [27, 48], rightHand: [74, 44],
        leftFoot: [40, 88], rightFoot: [66, 88]
      }
    },
    {
      t: 5000,
      hr: 154,
      speed: 7.8,
      boardRoll: 14.2,
      poseConfidence: 0.86,
      syncMs: 3.2,
      leftLoad: 0.63,
      rightLoad: 0.37,
      copL: [59, 60],
      copR: [45, 68],
      pressureL: [43,54,59,50,68,77,75,82,88,91,80,70,65,59,55,48],
      pressureR: [20,25,30,23,33,42,39,44,49,48,43,37,34,31,27,24],
      joints: {
        head: [57, 18], neck: [55, 30], pelvis: [48, 58],
        leftHand: [31, 44], rightHand: [78, 49],
        leftFoot: [39, 88], rightFoot: [64, 88]
      }
    }
  ]
};
