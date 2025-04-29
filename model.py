import os
import csv
from pathlib import Path
from dataclasses import dataclass, fields, astuple
import sys
import time
import math
from typing import List, Optional, Tuple
from collections import deque
import matplotlib.pyplot as plt # 导入绘图库
import matplotlib.font_manager as fm # 导入字体管理器
import numpy as np             # 导入 numpy 用于生成数据范围

# --- 配置 Matplotlib 字体 ---
# 尝试查找并设置一个支持中文的字体
# 你可以根据你的系统替换为其他可用字体，如 'Microsoft YaHei', 'WenQuanYi Micro Hei', 'Noto Sans CJK SC'等
preferred_fonts = ['SimHei', 'WenQuanYi Micro Hei', 'Arial Unicode MS'] # 备选字体列表
font_path = None
for font_name in preferred_fonts:
    try:
        font_path = fm.findfont(fm.FontProperties(family=font_name))
        if font_path:
            print(f"信息：找到可用字体 '{font_name}' at {font_path}")
            plt.rcParams['font.family'] = font_name
            # 如果设置了 CJK 字体，通常需要设置这个以正确显示负号
            plt.rcParams['axes.unicode_minus'] = False
            break
    except Exception:
        continue # 字体未找到，尝试下一个

if not font_path:
    print("警告：未能找到指定的 preferred_fonts 中的任何字体。将使用 Matplotlib 默认字体，可能无法正确显示 CJK 字符。")
    # 如果找不到指定字体，确保恢复 unicode minus 的默认设置可能更安全
    plt.rcParams['axes.unicode_minus'] = True

@dataclass
class DataPoint:
    """表示一个亮度数据点"""
    timestamp: int
    ambient_light: int
    screen_brightness: int
    is_manual_adjustment: bool

    # Helper to get field names for CSV header
    @classmethod
    def get_fieldnames(cls):
        return [field.name for field in fields(cls)]

class DataLogger:
    """
    负责记录和读取亮度数据点到 CSV 文件。
    模拟 Zig 版本 DataLogger 的核心功能。
    """
    def __init__(self):
        """
        初始化 DataLogger，确定日志文件路径并确保文件和目录存在。
        """
        config_dir_path = self._get_config_dir()
        config_dir_path.mkdir(parents=True, exist_ok=True) # 确保目录存在
        self.log_path = config_dir_path / "brightness_data.csv"
        self._ensure_csv_header()

    def _get_config_dir(self) -> Path:
        """获取配置目录路径 (XDG_CONFIG_HOME 或 ~/.config)"""
        xdg_config_home = os.getenv("XDG_CONFIG_HOME")
        if xdg_config_home:
            base_path = Path(xdg_config_home)
        else:
            home = os.getenv("HOME")
            if not home:
                # 在 Zig 版本中，这里会返回错误。
                # 在 Python 中，我们可以抛出异常或提供一个默认值。
                # 为了简单起见，我们使用当前目录作为后备，但这可能不是最佳选择。
                print("警告：无法确定 HOME 或 XDG_CONFIG_HOME 目录，将在当前目录创建配置。", file=sys.stderr)
                # 或者 raise OSError("无法确定用户配置目录 (HOME 或 XDG_CONFIG_HOME)")
                base_path = Path.home() / ".config" # 尝试 .config 作为最后的手段

        return base_path / "beelight"

    def _ensure_csv_header(self):
        """如果日志文件是空的，写入 CSV 表头"""
        if not self.log_path.exists() or self.log_path.stat().st_size == 0:
            try:
                with open(self.log_path, 'w', newline='', encoding='utf-8') as f:
                    writer = csv.writer(f)
                    writer.writerow(DataPoint.get_fieldnames())
            except IOError as e:
                print(f"错误：无法写入 CSV 文件头到 {self.log_path}: {e}", file=sys.stderr)
                # 根据需要可以重新抛出异常
                # raise

    def log_data_point(self, data: DataPoint):
        """
        将单个 DataPoint 记录到 CSV 文件末尾。

        Args:
            data: 要记录的 DataPoint 对象。
        """
        try:
            with open(self.log_path, 'a', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                # 将布尔值转换为 1 或 0，与 Zig 版本一致
                row = list(astuple(data))
                row[DataPoint.get_fieldnames().index('is_manual_adjustment')] = 1 if data.is_manual_adjustment else 0
                writer.writerow(row)
                # Python 的 'with open' 在退出时通常会刷新缓冲区，
                # 但显式调用 flush 可以更接近 sync 的行为（尽管不完全相同）
                f.flush()
                os.fsync(f.fileno()) # 更接近 Zig 的 file.sync()
        except IOError as e:
            print(f"错误：无法写入数据到 {self.log_path}: {e}", file=sys.stderr)
            # 根据需要可以重新抛出异常
            # raise

    def read_historical_data(self) -> List[DataPoint]:
        """
        从 CSV 文件读取所有历史数据点。

        Returns:
            一个包含所有 DataPoint 对象的列表。如果文件不存在或无法读取，
            返回空列表并打印错误。
        """
        data_points = []
        if not self.log_path.exists():
            print(f"信息：日志文件 {self.log_path} 不存在。", file=sys.stderr)
            return data_points

        try:
            with open(self.log_path, 'r', newline='', encoding='utf-8') as f:
                reader = csv.reader(f)
                header = next(reader, None) # 读取并跳过表头

                if not header or header != DataPoint.get_fieldnames():
                    print(f"警告：CSV 文件 {self.log_path} 表头不匹配或为空。", file=sys.stderr)
                    # 你可以选择在这里停止或尝试继续处理
                    # return data_points

                for row in reader:
                    if len(row) != len(DataPoint.get_fieldnames()):
                        print(f"警告：跳过格式错误的行: {row}", file=sys.stderr)
                        continue
                    try:
                        timestamp = int(row[0])
                        ambient_light = int(row[1])
                        screen_brightness = int(row[2])
                        # 将 1/0 转换回布尔值
                        is_manual_adjustment = bool(int(row[3]))

                        data_points.append(DataPoint(
                            timestamp=timestamp,
                            ambient_light=ambient_light,
                            screen_brightness=screen_brightness,
                            is_manual_adjustment=is_manual_adjustment
                        ))
                    except ValueError as e:
                        print(f"警告：跳过无法解析的行 {row}: {e}", file=sys.stderr)
                        continue
        except IOError as e:
            print(f"错误：无法读取数据从 {self.log_path}: {e}", file=sys.stderr)
        except Exception as e: # 捕获其他潜在错误，如 StopIteration (空文件)
             print(f"读取文件时发生意外错误 {self.log_path}: {e}", file=sys.stderr)


        return data_points

@dataclass
class TimeFeatures:
    """从时间戳提取的时间特征"""
    hour: int
    is_day: bool

    @staticmethod
    def from_timestamp(timestamp: int) -> 'TimeFeatures':
        """根据 Unix 时间戳计算时间特征"""
        # 使用 time 模块处理时间转换，更健壮
        dt_object = time.localtime(timestamp)
        hour = dt_object.tm_hour
        # 简单判断白天：6点到18点 (不含18点)
        is_day = 6 <= hour < 18
        return TimeFeatures(hour=hour, is_day=is_day)

@dataclass
class WeightedDataPoint:
    """带有权重的亮度数据点，用于分箱"""
    brightness: int
    weight: float
    timestamp: int

class AdaptiveBin:
    """自适应分箱，存储加权数据点"""
    def __init__(self, min_value: int, max_value: int, max_points: int = 50):
        self.min_value = min_value
        self.max_value = max_value
        self.points: List[WeightedDataPoint] = []
        self.total_weight: float = 0.0
        self.max_points = max_points # 每个 bin 存储的最大点数

    def update(self, brightness: int, weight: float, timestamp: int):
        """向分箱中添加或更新数据点"""
        self.points.append(WeightedDataPoint(brightness, weight, timestamp))
        self.total_weight += weight

        # 如果数据点过多，移除权重最小的点
        if len(self.points) > self.max_points:
            min_weight_idx = 0
            min_weight = self.points[0].weight
            for i, point in enumerate(self.points):
                if point.weight < min_weight:
                    min_weight = point.weight
                    min_weight_idx = i

            removed_point = self.points.pop(min_weight_idx)
            self.total_weight -= removed_point.weight

    def get_weighted_average(self) -> Optional[float]:
        """计算分箱内亮度的加权平均值"""
        if not self.points or self.total_weight == 0:
            return None

        weighted_sum = sum(p.brightness * p.weight for p in self.points)
        return weighted_sum / self.total_weight

    def cleanup(self, current_timestamp: int, max_age_seconds: int):
         """移除超过最大时效的数据点"""
         new_points = []
         new_total_weight = 0.0
         for point in self.points:
             age = current_timestamp - point.timestamp
             if age <= max_age_seconds:
                 new_points.append(point)
                 new_total_weight += point.weight
         self.points = new_points
         self.total_weight = new_total_weight


class EnhancedBrightnessModel:
    """
    增强亮度模型（基于自适应分箱）
    """
    def __init__(self, min_ambient: int = 0, max_ambient: int = 2000, bin_count: int = 10,
                 time_weight: float = 0.3, recency_weight: float = 0.4, activity_weight: float = 0.3):
        if bin_count <= 0:
            raise ValueError("bin_count 必须为正数")
        if min_ambient >= max_ambient:
             raise ValueError("min_ambient 必须小于 max_ambient")

        self.ambient_bins: List[AdaptiveBin] = []
        self.time_weight = time_weight
        self.recency_weight = recency_weight
        self.activity_weight = activity_weight
        # 使用 deque 实现固定长度的滑动窗口
        self.last_predictions = deque(maxlen=3)
        self.max_age_seconds = 7 * 24 * 3600  # 一周

        # 初始化分箱
        bin_size = (max_ambient - min_ambient) // bin_count
        for i in range(bin_count):
            bin_min = min_ambient + i * bin_size
            # 最后一个 bin 包含所有剩余值
            bin_max = max_ambient if (i == bin_count - 1) else (bin_min + bin_size)
            self.ambient_bins.append(AdaptiveBin(bin_min, bin_max))

    def _is_outlier(self, new_point: DataPoint, last_point: Optional[DataPoint]) -> bool:
        """判断是否为异常点（基于亮度和环境光变化）"""
        if last_point is None:
            return False
        brightness_diff = abs(new_point.screen_brightness - last_point.screen_brightness)
        ambient_diff = abs(new_point.ambient_light - last_point.ambient_light)
        # 阈值与 Zig 版本保持一致
        return brightness_diff > 80 or ambient_diff > 1200

    def _find_last_point_in_bins(self) -> Optional[DataPoint]:
         """在所有 bin 中查找最新的数据点（近似 Zig 版本逻辑）"""
         latest_timestamp = -1
         last_point_info: Optional[Tuple[int, int]] = None # (timestamp, brightness) in a bin

         for bin_ in self.ambient_bins:
             if bin_.points:
                 # 获取 bin 中最新的点
                 current_last_point = max(bin_.points, key=lambda p: p.timestamp)
                 if current_last_point.timestamp > latest_timestamp:
                     latest_timestamp = current_last_point.timestamp
                     # 近似 ambient_light 使用 bin 的中值， brightness 使用该点的亮度
                     approx_ambient = (bin_.min_value + bin_.max_value) // 2
                     last_point_info = (latest_timestamp, approx_ambient, current_last_point.brightness)

         if last_point_info:
             ts, amb, bright = last_point_info
             # 创建一个近似的 DataPoint 用于异常值比较
             return DataPoint(timestamp=ts, ambient_light=amb, screen_brightness=bright, is_manual_adjustment=True)
         return None


    def adapt_bins(self, historical_data: List[DataPoint]):
        """根据历史数据的环境光分布自适应调整分箱边界"""
        if len(historical_data) < len(self.ambient_bins) * 2: # 确保有足够数据点
            print("信息：历史数据点不足，无法进行自适应分箱。", file=sys.stderr)
            return

        ambient_list = sorted([d.ambient_light for d in historical_data])
        bin_count = len(self.ambient_bins)

        try:
            for i, bin_ in enumerate(self.ambient_bins):
                # 计算分位数的索引
                start_idx = (i * len(ambient_list)) // bin_count
                # 确保 end_idx 不会超出列表范围
                end_idx = min(((i + 1) * len(ambient_list)) // bin_count -1, len(ambient_list) - 1)
                if start_idx >= len(ambient_list) or end_idx < 0 or start_idx > end_idx:
                     print(f"警告：无法为 bin {i} 确定有效的索引范围 ({start_idx}-{end_idx})，跳过此 bin 的调整。", file=sys.stderr)
                     continue

                bin_.min_value = ambient_list[start_idx]
                # 最后一个 bin 包含到最大值
                if i == bin_count - 1:
                    bin_.max_value = ambient_list[-1]
                else:
                     bin_.max_value = ambient_list[end_idx]

                 # 确保 min < max，虽然排序后理论上应该如此，但以防万一
                if bin_.min_value >= bin_.max_value and i < bin_count -1 :
                    # 如果发生重叠或无效，尝试向前或向后扩展一点
                    if end_idx + 1 < len(ambient_list):
                         bin_.max_value = ambient_list[end_idx + 1]
                    # 如果仍然无效，可能需要更复杂的逻辑或保持不变
                    if bin_.min_value >= bin_.max_value:
                         print(f"警告：调整后 bin {i} 的范围无效 ({bin_.min_value}-{bin_.max_value})，可能需要检查数据分布。", file=sys.stderr)
                         # 可以选择重置为默认值或保持之前的状态


        except IndexError as e:
            print(f"错误：自适应分箱时发生索引错误: {e}", file=sys.stderr)


    def _nonlinear_map(self, ambient: int) -> float:
        """环境光的非线性映射 (Sigmoid)"""
        try:
            # 避免过大或过小的指数导致 OverflowError 或精度问题
            scaled_ambient = max(-700, min(700, -float(ambient) / 300.0))
            return 1.0 / (1.0 + math.exp(scaled_ambient))
        except OverflowError:
            # 如果 ambient 非常负，结果趋近于 0；如果非常正，趋近于 1
            return 0.0 if ambient < 0 else 1.0

    def _calculate_weight(self, current_time_features: TimeFeatures, point_time_features: TimeFeatures,
                          time_diff_seconds: int, is_active: bool) -> float:
        """计算数据点的权重，考虑时间、新近度和活动状态"""
        # 时间相关性权重 (白天 vs 夜晚)
        time_similarity = 1.0 if current_time_features.is_day == point_time_features.is_day else 0.2
        time_weight_component = self.time_weight * time_similarity

        # 时间衰减权重 (越近权重越高)
        age_factor = max(0.0, 1.0 - float(time_diff_seconds) / float(self.max_age_seconds))
        recency_weight_component = self.recency_weight * age_factor

        # 活动状态权重 (活跃时权重更高)
        activity_similarity = 1.0 if is_active else 0.5
        activity_weight_component = self.activity_weight * activity_similarity

        # 总权重是各部分之和
        return time_weight_component + recency_weight_component + activity_weight_component

    def train(self, data_point: DataPoint, current_timestamp: int, is_active: bool):
        """使用单个手动调整的数据点训练模型"""
        # 只使用手动调整的数据点进行训练
        if not data_point.is_manual_adjustment:
            return

        # 异常点过滤
        last_point = self._find_last_point_in_bins()
        if self._is_outlier(data_point, last_point):
             print(f"信息：检测到异常点，跳过训练: {data_point}", file=sys.stderr)
             return

        current_time_features = TimeFeatures.from_timestamp(current_timestamp)
        point_time_features = TimeFeatures.from_timestamp(data_point.timestamp)
        time_diff = max(0, current_timestamp - data_point.timestamp) # 确保时间差非负

        weight = self._calculate_weight(current_time_features, point_time_features, time_diff, is_active)

        # 找到对应的光照区间并更新
        target_bin: Optional[AdaptiveBin] = None
        for bin_ in self.ambient_bins:
            # 注意边界条件：包含最小值，不包含最大值 (最后一个 bin 除外)
            is_last_bin = (bin_ == self.ambient_bins[-1])
            if (bin_.min_value <= data_point.ambient_light < bin_.max_value) or \
               (is_last_bin and data_point.ambient_light >= bin_.min_value):
                target_bin = bin_
                break

        if target_bin:
            target_bin.update(data_point.screen_brightness, weight, data_point.timestamp)
        else:
            # 如果数据点不在任何定义的 bin 内（可能由于 adapt_bins 后的间隙或极端值）
            print(f"警告：环境光值 {data_point.ambient_light} 未落在任何 bin 中，无法训练。", file=sys.stderr)


    def predict(self, ambient_light: int, timestamp: int, is_active: bool) -> Optional[float]:
        """根据当前环境光、时间和活动状态预测屏幕亮度"""
        # 非线性预处理 (可选，取决于效果)
        # mapped_ambient = self._nonlinear_map(ambient_light)
        # 如果使用映射后的值，后续查找 bin 需要基于 mapped_ambient
        current_ambient = float(ambient_light) # 使用原始值查找 bin

        main_bin: Optional[AdaptiveBin] = None
        main_bin_index: Optional[int] = None

        # 找到主要区间
        for i, bin_ in enumerate(self.ambient_bins):
             is_last_bin = (i == len(self.ambient_bins) - 1)
             # 使用原始环境光值比较
             if (bin_.min_value <= current_ambient < bin_.max_value) or \
                (is_last_bin and current_ambient >= bin_.min_value):
                 main_bin = bin_
                 main_bin_index = i
                 break

        if main_bin is None or main_bin_index is None:
            # 如果找不到对应的 bin（例如环境光低于 min_ambient 或高于 max_ambient 且未被最后一个 bin 覆盖）
             print(f"警告：环境光值 {ambient_light} 未落在任何 bin 中，无法预测。", file=sys.stderr)
             # 可以考虑返回最近 bin 的值或 None
             return None

        # 获取主区间的加权平均预测值
        main_prediction = main_bin.get_weighted_average()
        if main_prediction is None:
            # 如果主 bin 为空，尝试查找相邻的有数据的 bin
            # 简单策略：向前查找，再向后查找
            found_prediction = None
            for idx_offset in range(1, len(self.ambient_bins)):
                prev_idx = main_bin_index - idx_offset
                next_idx = main_bin_index + idx_offset
                if prev_idx >= 0:
                     prev_pred = self.ambient_bins[prev_idx].get_weighted_average()
                     if prev_pred is not None:
                          found_prediction = prev_pred
                          break
                if next_idx < len(self.ambient_bins):
                     next_pred = self.ambient_bins[next_idx].get_weighted_average()
                     if next_pred is not None:
                          found_prediction = next_pred
                          break
            if found_prediction is None:
                 return None # 如果所有 bin 都为空，无法预测
            main_prediction = found_prediction # 使用找到的相邻 bin 的预测值


        # 应用时间和活动状态调整因子
        time_features = TimeFeatures.from_timestamp(timestamp)
        time_factor = 1.0 if time_features.is_day else 0.8
        activity_factor = 1.0 if is_active else 0.9

        adjusted_prediction = main_prediction * time_factor * activity_factor

        # --- 区间边界插值 ---
        # 计算当前环境光在主 bin 中的相对位置
        bin_range = float(main_bin.max_value - main_bin.min_value)
        position_in_bin = float(current_ambient - main_bin.min_value) / bin_range if bin_range > 0 else 0.5

        # 只在靠近边界时进行插值 (例如，在 bin 的前 20% 或后 20%)
        interpolation_threshold = 0.2
        neighbor_prediction: Optional[float] = None
        interpolation_weight: float = 0.0

        if position_in_bin < interpolation_threshold and main_bin_index > 0:
            # 靠近下边界，与前一个 bin 插值
            prev_bin = self.ambient_bins[main_bin_index - 1]
            neighbor_prediction = prev_bin.get_weighted_average()
            if neighbor_prediction is not None:
                 # 权重与离边界的距离成反比，范围 [0, 1]
                 interpolation_weight = (interpolation_threshold - position_in_bin) / interpolation_threshold
                 neighbor_prediction *= time_factor * activity_factor # 对邻居应用相同调整

        elif position_in_bin > (1.0 - interpolation_threshold) and main_bin_index < len(self.ambient_bins) - 1:
            # 靠近上边界，与后一个 bin 插值
            next_bin = self.ambient_bins[main_bin_index + 1]
            neighbor_prediction = next_bin.get_weighted_average()
            if neighbor_prediction is not None:
                # 权重与离边界的距离成反比
                interpolation_weight = (position_in_bin - (1.0 - interpolation_threshold)) / interpolation_threshold
                neighbor_prediction *= time_factor * activity_factor # 对邻居应用相同调整

        # 应用插值
        if neighbor_prediction is not None and 0 < interpolation_weight <= 1.0:
            adjusted_prediction = adjusted_prediction * (1.0 - interpolation_weight) + neighbor_prediction * interpolation_weight

        # --- 滑动平均平滑 ---
        self.last_predictions.append(adjusted_prediction)
        # 计算 deque 中所有元素的平均值
        if not self.last_predictions: # 如果队列为空（理论上不应发生）
            smoothed_prediction = adjusted_prediction
        else:
            smoothed_prediction = sum(self.last_predictions) / len(self.last_predictions)


        # 限制预测值在合理范围 (e.g., 0-100)
        final_prediction = max(0.0, min(100.0, smoothed_prediction))

        return final_prediction

    def cleanup(self, current_timestamp: int):
        """清理所有分箱中过时的数据点"""
        for bin_ in self.ambient_bins:
            bin_.cleanup(current_timestamp, self.max_age_seconds)

    def load_historical_data(self, data_points: List[DataPoint], current_timestamp: int, is_active: bool):
         """使用历史数据批量训练模型（预热）"""
         print(f"开始使用 {len(data_points)} 条历史数据训练模型...")
         # 可以先进行自适应分箱
         self.adapt_bins(data_points)
         print("自适应分箱完成。")
         # 按时间顺序训练
         sorted_data = sorted(data_points, key=lambda p: p.timestamp)
         count = 0
         for point in sorted_data:
             # 对于历史数据，我们可以假设其记录时的 is_active 状态未知或不重要，
             # 或者使用当前的 is_active 状态。这里使用当前状态。
             # 同样，current_timestamp 对历史数据的权重计算可能不理想，
             # 可以考虑使用 point.timestamp + 一个小的固定值，或者就用 point.timestamp
             self.train(point, point.timestamp, is_active=True) # 假设历史操作时是活跃的
             count +=1
             if count % 100 == 0:
                 print(f"已处理 {count}/{len(sorted_data)} 条历史数据...")
         print("历史数据训练完成。")

# --- 示例用法 和 绘图 ---
if __name__ == "__main__":
    # 1. 初始化 DataLogger 和 Model
    logger = DataLogger()
    # 使用更宽的环境光范围和更多 bin 来进行可视化
    model = EnhancedBrightnessModel(min_ambient=0, max_ambient=3000, bin_count=15)

    # 2. 读取历史数据
    print("读取历史数据...")
    historical_data = logger.read_historical_data()
    manual_adjustments = [p for p in historical_data if p.is_manual_adjustment]
    print(f"找到 {len(historical_data)} 条历史记录, 其中 {len(manual_adjustments)} 条是手动调整。")

    # --- 绘图准备 ---
    plt.figure(figsize=(12, 8)) # 创建一个图形窗口

    # 定义要测试的环境光范围
    ambient_range = np.linspace(model.ambient_bins[0].min_value, model.ambient_bins[-1].max_value, 300)
    current_ts = int(time.time())
    is_active_for_plot = True # 假设在绘图时用户是活跃的

    # --- 可选：绘制训练前的预测曲线 ---
    # predictions_before = [model.predict(int(amb), current_ts, is_active_for_plot) for amb in ambient_range]
    # # 过滤掉 None 值
    # valid_indices_before = [i for i, p in enumerate(predictions_before) if p is not None]
    # if valid_indices_before:
    #     plt.plot(ambient_range[valid_indices_before],
    #              [predictions_before[i] for i in valid_indices_before],
    #              label='预测 (训练前)', linestyle='--', color='gray', alpha=0.7)

    # 3. 使用历史数据训练模型
    if historical_data:
        model.load_historical_data(historical_data, current_ts, is_active_for_plot)
    else:
        print("无历史数据可用于训练。")
        # 如果没有历史数据，可以添加一些虚拟的训练点来观察效果
        # print("添加一些虚拟训练点...")
        # virtual_points = [
        #     DataPoint(timestamp=current_ts - 3600, ambient_light=100, screen_brightness=20, is_manual_adjustment=True),
        #     DataPoint(timestamp=current_ts - 1800, ambient_light=500, screen_brightness=50, is_manual_adjustment=True),
        #     DataPoint(timestamp=current_ts - 600, ambient_light=1500, screen_brightness=85, is_manual_adjustment=True),
        # ]
        # model.load_historical_data(virtual_points, current_ts, is_active_for_plot)


    # --- 绘制训练后的预测曲线 ---
    predictions_after = [model.predict(int(amb), current_ts, is_active_for_plot) for amb in ambient_range]
    # 过滤掉 None 值
    valid_indices_after = [i for i, p in enumerate(predictions_after) if p is not None]
    if valid_indices_after:
         # 使用 numpy 索引来获取有效的 x 和 y 值
        ambient_valid_after = ambient_range[valid_indices_after]
        predictions_valid_after = [predictions_after[i] for i in valid_indices_after]
        plt.plot(ambient_valid_after, predictions_valid_after, label='模型预测 (训练后)', color='blue', linewidth=2)

    # --- 绘制历史数据点 ---
    if manual_adjustments:
        ambient_hist = [p.ambient_light for p in manual_adjustments]
        brightness_hist = [p.screen_brightness for p in manual_adjustments]
        plt.scatter(ambient_hist, brightness_hist, label='手动调整记录', color='red', alpha=0.6, s=50, edgecolors='k') # s是点的大小

    # --- 可选：绘制分箱边界 ---
    print("\n当前分箱边界:")
    bin_label_added = False # 确保标签只添加一次
    for i, bin_ in enumerate(model.ambient_bins):
        print(f"  Bin {i}: [{bin_.min_value}, {bin_.max_value})")
        # 只绘制内部边界线以避免重复
        if i > 0:
            current_label = '自适应分箱边界' if not bin_label_added else None
            plt.axvline(x=bin_.min_value, color='green', linestyle=':', linewidth=1, alpha=0.5, label=current_label)
            if not bin_label_added: bin_label_added = True # 标记标签已添加
    # 如果只有一个 bin，或者需要绘制第一个 bin 的起始边界（通常是 min_ambient）
    if len(model.ambient_bins) > 0 and not bin_label_added:
         plt.axvline(x=model.ambient_bins[0].min_value, color='green', linestyle=':', linewidth=1, alpha=0.5, label='自适应分箱边界')



    # --- 图形设置 ---
    plt.xlabel("环境光照度 (Ambient Light)")
    plt.ylabel("屏幕亮度 (Screen Brightness %)")
    plt.title("增强亮度模型预测与历史数据")
    plt.legend() # 显示图例
    plt.grid(True, linestyle='--', alpha=0.6) # 添加网格
    plt.ylim(0, 105) # 设置 Y 轴范围略大于 0-100
    # 根据数据动态设置 X 轴范围，或者固定一个较大的范围
    if historical_data:
        # 考虑历史数据和最后一个 bin 的最大值来确定 x 轴上限
        max_hist_ambient = max(p.ambient_light for p in historical_data) if historical_data else 0
        max_bin_ambient = model.ambient_bins[-1].max_value if model.ambient_bins else 0
        upper_xlim = max(max_bin_ambient, max_hist_ambient) * 1.1
        plt.xlim(0, upper_xlim if upper_xlim > 0 else 3000) # 避免上限为0
    else:
         plt.xlim(0, model.ambient_bins[-1].max_value if model.ambient_bins else 3000)

    # --- 显示图形 ---
    print("\n正在生成图表...")
    plt.show()

    # --- (原有的模拟实时场景代码可以保留或注释掉) ---
    # print("\n模拟实时场景:")
    # current_ambient = 600
    # predicted_brightness = model.predict(current_ambient, current_ts, is_user_active)
    # ... (之前的模拟代码) ...
