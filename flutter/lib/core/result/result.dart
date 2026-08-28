import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:equatable/equatable.dart';

/// A total, exception-free result type used across every architectural seam.
///
/// Dart has no `Either` in its core library and `dartz` brings a functional
/// vocabulary most Flutter teams do not share. A two-case sealed class gives
/// the same guarantee - the analyser forces both branches to be handled - in
/// terms any Dart reader already knows.
sealed class Result<T> extends Equatable {
  const Result();

  const factory Result.success(T value) = Success<T>;

  const factory Result.failure(Failure failure) = FailureResult<T>;

  bool get isSuccess => this is Success<T>;

  bool get isFailure => this is FailureResult<T>;

  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        FailureResult<T>() => null,
      };

  Failure? get failureOrNull => switch (this) {
        Success<T>() => null,
        FailureResult<T>(:final failure) => failure,
      };

  /// Collapses both branches into a single value.
  R fold<R>(R Function(T value) onSuccess, R Function(Failure failure) onFailure) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        FailureResult<T>(:final failure) => onFailure(failure),
      };

  /// Transforms a successful value, leaving failures untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Result<R>.success(transform(value)),
        FailureResult<T>(:final failure) => Result<R>.failure(failure),
      };

  /// Chains another fallible step, short-circuiting on the first failure.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
        Success<T>(:final value) => transform(value),
        FailureResult<T>(:final failure) => Result<R>.failure(failure),
      };
}

final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  List<Object?> get props => <Object?>[value];
}

final class FailureResult<T> extends Result<T> {
  const FailureResult(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => <Object?>[failure];
}

/// Runs [body], converting any escaped exception into [onError]'s failure.
///
/// Every data-source method funnels through this, which is how the promise
/// "nothing above the data layer ever sees a raw exception" is actually kept
/// rather than merely intended.
Future<Result<T>> guard<T>(
  Future<T> Function() body, {
  required Failure Function(Object error, StackTrace stackTrace) onError,
}) async {
  try {
    return Result<T>.success(await body());
  } catch (error, stackTrace) {
    return Result<T>.failure(onError(error, stackTrace));
  }
}
