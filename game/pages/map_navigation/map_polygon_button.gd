extends Button
## 仅多边形内部响应鼠标；矩形包围盒外角不能误选相邻房间。
var hit_polygon := PackedVector2Array()

func _has_point(point: Vector2) -> bool:
	return hit_polygon.size() >= 3 and Geometry2D.is_point_in_polygon(point, hit_polygon)
