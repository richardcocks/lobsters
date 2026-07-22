# Batch-loads the per-story lookup data that Notification#is_high_quality? needs,
# so rendering a page of notifications costs three queries instead of three per row.
class NotificationDisplayHydrator
  def initialize(notifications, user)
    comments = notifications.filter_map { |n| n.notifiable if n.notifiable_type == "Comment" }

    if user.nil? || comments.empty?
      @replier_comment_ids = {}
      @flagged_comment_ids = Set.new
      @hidden_story_ids = Set.new
    else
      story_ids = comments.map(&:story_id).uniq
      author_ids = comments.map(&:user_id).uniq

      # Superset of the pairs we need (any page-author on any page-story); ids only.
      @replier_comment_ids = Comment.where(story_id: story_ids, user_id: author_ids)
        .pluck(:user_id, :story_id, :id)
        .group_by { |user_id, story_id, _id| [user_id, story_id] }
        .transform_values { |rows| rows.map(&:last) }
      @flagged_comment_ids = user.votes.where(story_id: story_ids, vote: -1).pluck(:comment_id).to_set
      @hidden_story_ids = user.hidings.where(story_id: story_ids).pluck(:story_id).to_set
    end

    notifications.each { |n| n.display_batch = self }
  end

  def replier_comment_ids(author_id, story_id)
    @replier_comment_ids.fetch([author_id, story_id], [])
  end

  def flagged_replier?(comment_ids)
    comment_ids.any? { |id| @flagged_comment_ids.include?(id) }
  end

  def hidden_story?(story_id)
    @hidden_story_ids.include?(story_id)
  end
end
