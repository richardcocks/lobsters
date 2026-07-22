class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true

  validates :user_id, uniqueness: {scope: [:notifiable_type, :notifiable_id]}
  validates :notifiable_type, presence: true, length: {maximum: 255}

  scope :of_comments, -> { where(notifiable_type: "Comment") }
  scope :of_messages, -> { where(notifiable_type: "Message") }
  scope :of_mod_mail_messages, -> { where(notifiable_type: "ModMailMessage") }
  scope :read, -> { where.not(read_at: nil) }
  scope :unread, -> { where(read_at: nil) }

  before_validation on: :create do
    self.read_at = Time.current if !should_display?
  end

  include Token

  # Set by NotificationDisplayHydrator so is_high_quality? can answer from
  # batch-loaded data instead of issuing per-notification queries.
  attr_accessor :display_batch

  def should_display?
    case notifiable
    when Message
      should_display_message?
    when ModMailMessage
      true
    when Comment
      should_display_comment?
    end
  end

  def should_display_message?
    true
  end

  def should_display_comment?
    return false unless user_wants_notification?
    return false unless is_high_quality?

    true
  end

  private

  def user_wants_notification?
    comment = notifiable

    # Check if this is a mention notification
    if comment.comment.match?(Markdowner::USERNAME_MENTION)
      return user.inbox_mentions?
    end

    # For reply notifications, always show (user settings handled elsewhere)
    true
  end

  def is_high_quality?
    comment = notifiable
    story = comment.story
    parent_comment = comment.parent_comment

    if display_batch
      replier_comment_ids = display_batch.replier_comment_ids(comment.user_id, story.id)
      user_has_flagged_replier = display_batch.flagged_replier?(replier_comment_ids)
      user_has_hidden_story = display_batch.hidden_story?(story.id)
    else
      replier_comment_ids = comment.user.comments.where(story_id: story.id).ids
      user_has_flagged_replier = user.votes.where(story_id: story.id, vote: -1, comment_id: replier_comment_ids).exists?
      user_has_hidden_story = user.hidings.where(story_id: story.id).exists?
    end

    bad_properties = {
      bad_story: story.score <= story.flags,
      is_gone: comment.is_gone?,
      bad_comment: comment.score <= comment.flags,
      bad_parent_comment: parent_comment.nil? ? false : parent_comment.score <= parent_comment.flags || parent_comment.is_gone?,
      user_has_flagged_replier: user_has_flagged_replier,
      user_has_hidden_story: user_has_hidden_story,
      user_has_filtered_tags_on_story: !(story.tags & user.tag_filter_tags).empty?
    }.compact_blank

    bad_properties.empty?
  end
end
