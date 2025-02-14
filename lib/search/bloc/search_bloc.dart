import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_transform/stream_transform.dart';

import 'package:lemmy/lemmy.dart';
import 'package:thunder/account/models/account.dart';
import 'package:thunder/core/auth/helpers/fetch_account.dart';

import 'package:thunder/core/singletons/lemmy_client.dart';

part 'search_event.dart';
part 'search_state.dart';

const throttleDuration = Duration(milliseconds: 300);

EventTransformer<E> throttleDroppable<E>(Duration duration) {
  return (events, mapper) => droppable<E>().call(events.throttle(duration), mapper);
}

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc() : super(const SearchState()) {
    on<StartSearchEvent>(
      _startSearchEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ChangeCommunitySubsciptionStatusEvent>(
      _changeCommunitySubsciptionStatusEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ResetSearch>(
      _resetSearch,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ContinueSearchEvent>(
      _continueSearchEvent,
      transformer: throttleDroppable(throttleDuration),
    );
  }

  Future<void> _resetSearch(ResetSearch event, Emitter<SearchState> emit) async {
    emit(state.copyWith(status: SearchStatus.initial));
  }

  Future<void> _startSearchEvent(StartSearchEvent event, Emitter<SearchState> emit) async {
    try {
      emit(state.copyWith(status: SearchStatus.loading));

      Account? account = await fetchActiveProfileAccount();
      Lemmy lemmy = LemmyClient.instance.lemmy;

      SearchResponse searchResponse = await lemmy.search(
        Search(
          auth: account?.jwt,
          q: event.query,
          page: 1,
          limit: 15,
          sort: SortType.Active,
        ),
      );

      return emit(state.copyWith(status: SearchStatus.success, results: searchResponse, page: 2));
    } on DioException catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      if (e.type == DioExceptionType.receiveTimeout) {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: 'Error: Network timeout when attempting to search'));
      } else {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: e.toString()));
      }
    } catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _continueSearchEvent(ContinueSearchEvent event, Emitter<SearchState> emit) async {
    int attemptCount = 0;

    try {
      var exception;

      while (attemptCount < 2) {
        try {
          emit(state.copyWith(status: SearchStatus.refreshing, results: state.results));

          Account? account = await fetchActiveProfileAccount();
          Lemmy lemmy = LemmyClient.instance.lemmy;

          SearchResponse searchResponse = await lemmy.search(
            Search(
              auth: account?.jwt,
              q: event.query,
              page: state.page,
              limit: 15,
              sort: SortType.Active,
            ),
          );

          // Append the search results
          state.results?.communities.addAll(searchResponse.communities);
          state.results?.comments.addAll(searchResponse.comments);
          state.results?.posts.addAll(searchResponse.posts);
          state.results?.users.addAll(searchResponse.users);

          return emit(state.copyWith(status: SearchStatus.success, results: state.results, page: state.page + 1));
        } catch (e, s) {
          exception = e;
          attemptCount++;
          await Sentry.captureException(e, stackTrace: s);
        }
      }
    } on DioException catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      if (e.type == DioExceptionType.receiveTimeout) {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: 'Error: Network timeout when attempting to search'));
      } else {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: e.toString()));
      }
    } catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _changeCommunitySubsciptionStatusEvent(ChangeCommunitySubsciptionStatusEvent event, Emitter<SearchState> emit) async {
    try {
      emit(state.copyWith(status: SearchStatus.refreshing, results: state.results));

      Account? account = await fetchActiveProfileAccount();
      Lemmy lemmy = LemmyClient.instance.lemmy;

      if (account?.jwt == null) return;

      CommunityResponse communityResponse = await lemmy.followCommunity(FollowCommunity(
        auth: account!.jwt!,
        communityId: event.communityId,
        follow: event.follow,
      ));

      // Search for the community that was updated and update it with the response
      int communityToUpdateIndex = state.results!.communities.indexWhere((CommunityView communityView) => communityView.community.id == communityResponse.communityView.community.id);
      state.results!.communities[communityToUpdateIndex] = communityResponse.communityView;

      return emit(state.copyWith(status: SearchStatus.success, results: state.results));
    } on DioException catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      if (e.type == DioExceptionType.receiveTimeout) {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: 'Error: Network timeout when attempting to vote'));
      } else {
        return emit(state.copyWith(status: SearchStatus.networkFailure, errorMessage: e.toString()));
      }
    } catch (e, s) {
      await Sentry.captureException(e, stackTrace: s);

      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }
}
