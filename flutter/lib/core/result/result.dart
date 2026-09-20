import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:equatable/equatable.dart';

/// "It worked, here is the value" **or** "it failed, here is why" — as a
/// value you can return, not an exception you have to catch.
///
/// This is one of the two types you must understand to read this codebase
/// (the other is [Failure]). Almost every function that can fail returns
/// `Result<Something>`.
///
/// ## Reading it
///
/// ```dart
/// final Result<List<UploadTask>> result = await repository.readEligible(now);
///
/// result.fold(
///   (List<UploadTask> tasks) => print('got ${tasks.length}'),
///   (Failure failure) => print('failed: $failure'),
/// );
/// ```
///
/// ## Why not just throw?
///
/// An exception is invisible in a function's signature. A declaration like
/// `Future<List<Task>> readEligible()` tells you nothing about the four ways
/// it can fail, so callers forget to handle them and the app crashes in
/// front of a user.
///
/// `Result` puts the failure in the type, where it cannot be ignored.
///
/// ## Why a sealed class and not `dartz`'s `Either`
///
/// Dart has no `Either` in its core library, and `dartz` brings a functional
/// vocabulary most Flutter teams do not share. A two-case **sealed** class
/// gives the same guarantee — the analyser forces both branches to be handled
/// — in terms any Dart reader already knows.
///
/// ## The helpers below
///
/// [fold], [map] and [flatMap] cover the common shapes. They all share one
/// rule: **a failure passes straight through untouched.** Only [fold] can
/// turn a failure back into an ordinary value.
sealed class Result<T> extends Equatable {
  const Result();

  /// The happy path.
  const factory Result.success(T value) = Success<T>;

  /// The failure path, carrying one case from the [Failure] taxonomy.
  const factory Result.failure(Failure failure) = FailureResult<T>;

  bool get isSuccess => this is Success<T>;

  bool get isFailure => this is FailureResult<T>;

  /// The value, or `null` if this failed.
  ///
  /// Use when the reason genuinely does not matter to the caller.
  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        FailureResult<T>() => null,
      };

  /// The mirror of [valueOrNull].
  Failure? get failureOrNull => switch (this) {
        Success<T>() => null,
        FailureResult<T>(:final failure) => failure,
      };

  /// Collapses both branches into one ordinary value.
  ///
  /// This is how a `Result` finally *leaves* the Result world — typically in
  /// a Bloc, turning an outcome into state.
  ///
  /// [onSuccess] is called with the value, [onFailure] with the failure.
  /// Exactly one of them runs.
  R fold<R>(R Function(T value) onSuccess, R Function(Failure failure) onFailure) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        FailureResult<T>(:final failure) => onFailure(failure),
      };

  /// Transforms the value inside, leaving a failure untouched.
  ///
  /// Use when [transform] itself **cannot fail**.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Result<R>.success(transform(value)),
        FailureResult<T>(:final failure) => Result<R>.failure(failure),
      };

  /// Chains another step that can *itself* fail, stopping at the first
  /// failure.
  ///
  /// Use when [transform] returns a `Result` too — without this you would end
  /// up with a nested `Result<Result<T>>`.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
        Success<T>(:final value) => transform(value),
        FailureResult<T>(:final failure) => Result<R>.failure(failure),
      };
}

/// The success case. Carries the value.
final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  List<Object?> get props => <Object?>[value];
}

/// The failure case. Carries the reason.
final class FailureResult<T> extends Result<T> {
  const FailureResult(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => <Object?>[failure];
}

/// Runs [body] and converts **any** escaped exception into a [Result]
/// failure.
///
/// ## Why this function is load-bearing
///
/// Every adapter in this app carries the contract "this class never throws".
/// That promise is easy to state and easy to break — a vendor plugin throws a
/// `PlatformException` you did not anticipate, and it sails straight up into
/// the Bloc.
///
/// Every data-source method funnels through `guard`, which is how the promise
/// is actually *kept* rather than merely intended:
///
/// ```dart
/// Future<Result<void>> insert(UploadTask task) => guard(
///       () => _database.insert(task.toRow()),
///       onError: (Object e, StackTrace s) => StorageFailure(cause: e),
///     );
/// ```
///
/// [onError] receives the raw error and stack trace and decides which typed
/// [Failure] the rest of the app should see. That translation is the boundary
/// between "the platform's vocabulary" and "ours".
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
