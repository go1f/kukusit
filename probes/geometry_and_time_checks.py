"""Synthetic checks for architecture assumptions, not a posture detector."""
import json
import math


def sustained_alert_times(samples, threshold_seconds=12.0, maximum_gap=0.5):
    """Minimal persistence example: no missing interval counts as observation."""
    previous = None
    duration = 0.0
    emitted = False
    alerts = []
    for timestamp, abnormal in samples:
        if abnormal is not True:
            previous, duration, emitted = None, 0.0, False
            continue
        if previous is None or timestamp - previous > maximum_gap:
            duration, emitted = 0.0, False
        else:
            duration += timestamp - previous
        previous = timestamp
        if duration + 1e-9 >= threshold_seconds and not emitted:
            alerts.append(timestamp)
            emitted = True
    return alerts


def sample_range(start, count, step=1 / 6):
    return [(start + index * step, True) for index in range(count)]


def main():
    # A 360px-wide shoulder line with 36px height difference in a 16:9 frame.
    pixel_angle = math.degrees(math.atan2(36, 360))
    normalized_angle = math.degrees(math.atan2(36 / 720, 360 / 1280))
    restored_angle = math.degrees(math.atan2((36 / 720) * 720, (360 / 1280) * 1280))
    assert math.isclose(pixel_angle, restored_angle)
    assert not math.isclose(pixel_angle, normalized_angle)

    short_action = sustained_alert_times(sample_range(0, 19))
    continuous = sustained_alert_times(sample_range(0, 121))
    gap = sustained_alert_times(sample_range(0, 37) + sample_range(100, 37))
    unknown = sustained_alert_times(sample_range(0, 37) + [(6.2, None)] + sample_range(6.4, 37))
    assert short_action == []
    assert len(continuous) == 1 and math.isclose(continuous[0], 12.0)
    assert gap == []
    assert unknown == []

    # A synthetic pinhole example, with hypothetical centimetre distances.
    near_scale = 70 / 60
    result = {
        "input": "synthetic coordinates and timestamps; no camera or person",
        "shoulderAngleDegrees": {
            "correctPixelSpace": round(pixel_angle, 4),
            "incorrectNormalizedSpace": round(normalized_angle, 4),
            "restoredPixelSpace": round(restored_angle, 4),
        },
        "headVersusWholeBodyMovement": {
            "assumedDepthCm": {"baseline": 70, "near": 60},
            "wholeBodyFaceScale": round(near_scale, 4),
            "wholeBodyShoulderScale": round(near_scale, 4),
            "headOnlyFaceScale": round(near_scale, 4),
            "headOnlyShoulderScale": 1.0,
            "limitation": "scale ratios can be supporting evidence; they cannot establish neck angle or physical contact",
        },
        "persistenceChecks": {
            "threeSecondActionAlerts": short_action,
            "twentySecondContinuousAlerts": continuous,
            "sixSecondsThenNinetyFourSecondGapThenSixSecondsAlerts": gap,
            "sixSecondsThenUnknownThenSixSecondsAlerts": unknown,
        },
        "passed": True,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
